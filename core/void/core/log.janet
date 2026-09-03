### void/core/log — structured logger in the core. pino-parity by property, data-idiomatic by construction:
###
### - A record is a plain table {:ts :level :ns :msg ...kv} plus the
###   fiber-bound context — no format strings on the hot path, sinks
###   own the formatting.
### - The level macros (log/info ...) do not evaluate their arguments
###   when the level is off for the namespace: a disabled level is one
###   table lookup.
### - Levels are a per-namespace prefix tree ("my-app.orders" inherits
###   from "my-app"), changeable at runtime from the REPL/CLI.
### - Context is a dyn: (log/with-context {:request-id id} ...) binds
###   kv pairs to every record inside — the child-logger idea without
###   an object; (log/carrying f) transfers it into ev/go tasks.
### - Sinks are pluggable (extension point :void.core/log-sink): the
###   pretty stderr sink is synchronous (dev), the jdn-lines sink
###   writes from its own fiber behind a buffered channel and DROPS on
###   overflow (logs never take the service down; drops are counted).
###   :fatal always flushes synchronously.
### - Serializers (:void.core/log-serializer) shape well-known keys
###   (:err -> {:msg :stacktrace}); config [:log :redact] paths are
###   replaced wholesale. Config secret boxes already never print
###   (void/core/config).

# -- levels --------------------------------------------------------------

(def levels
  "Level keyword -> numeric severity."
  {:trace 10 :debug 20 :info 30 :warn 40 :error 50 :fatal 60})

(defn- level-num [l]
  (or (get levels l)
      (errorf "unknown log level %q (levels: :trace :debug :info :warn :error :fatal)" l)))

(def- root-default :info)

(def- state
  @{:root (level-num root-default)
    :tree @{}          # ns-string -> numeric minimum
    :memo @{}          # ns-string -> effective minimum (hot-path cache)
    :sinks nil         # nil = the default pretty sink
    :serializers @{}
    :redact []
    :dropped 0
    :closers @[]})     # async sink shutdown thunks (see close!)

(defn set-level!
  ``Set the minimum level for a namespace prefix ("my-app.orders"), or
  the root minimum with nil/"" — runtime-changeable:

      (log/set-level! "my-app.orders" :debug)
      (log/set-level! nil :warn)``
  [ns level]
  (def n (level-num level))
  (if (or (nil? ns) (= "" ns))
    (put state :root n)
    (put-in state [:tree (string ns)] n))
  (table/clear (state :memo))
  level)

(defn- parent-ns
  "\"a.b.c\" -> \"a.b\"; \"a\" -> \"\"."
  [s]
  (var last-dot nil)
  (loop [i :range [0 (length s)]]
    (when (= (chr ".") (s i)) (set last-dot i)))
  (if last-dot (string/slice s 0 last-dot) ""))

(defn level-for
  "The effective numeric minimum for a namespace: the longest dotted
  prefix with an explicit level, else the root minimum. Memoized —
  the disabled-level fast path is one table lookup."
  [ns]
  (or (get (state :memo) ns)
      (do
        (def tree (state :tree))
        (var cur (string ns))
        (var found nil)
        (while (and (nil? found) (not (empty? cur)))
          (if-let [n (get tree cur)]
            (set found n)
            (set cur (parent-ns cur))))
        (def n (or found (state :root)))
        (put (state :memo) (string ns) n)
        n)))

(defn enabled?
  "Is `level` on for `ns`? The macros call this before evaluating
  anything else."
  [ns level]
  (>= (level-num level) (level-for ns)))

# -- context -------------------------------------------------------------

(def context-dyn
  "The dyn carrying the bound log context of the current fiber."
  :void.core.log/context)

(defn context
  "The current bound context (or {})."
  []
  (or (dyn context-dyn) {}))

(defmacro with-context
  ``Bind extra kv pairs to every record emitted in `body` (per-fiber — the child logger of):

      (log/with-context {:request-id id} (handler req))``
  [kvs & body]
  ~(with-dyns [,context-dyn
               # skip the merge alloc on the common no-outer-context path
               (if-let [outer (,dyn ,context-dyn)]
                 (merge outer ,kvs)
                 ,kvs)]
     ,;body))

(defn carrying
  "Wrap `f` so it runs with the context bound at wrap time — for
  handing work to ev/go, whose fibers do not inherit dyns."
  [f]
  (def ctx (context))
  (fn carried [& args]
    (with-dyns [context-dyn ctx]
      (f ;args))))

# -- what an error says --------------------------------------------------

(def- error-message-keys
  # `:message` is the convention every structured throw in void already
  # follows — void/http/errors, the HTTP client, the server's reject,
  # void/db-mysql, void/datastar — and an application's channel or job
  # follows it because those did. `:msg` and `:error` are here because
  # somebody will write them and being right about the key is not the
  # point of the line that reports a failure.
  [:message :msg :error])

(defn message-of
  ``What an error value *says*, as a string.

  Errors in void are frequently values rather than strings — a status
  and a message, so that the code deciding whether to retry can read
  the status (is one). `describe` renders such a value as `<struct
  0xAAAA…>`, and that address was, until this function existed, what a
  failed job's record, a log line and `void: …` on the terminal actually
  said. Which is to say: the framework's own convention was being thrown
  away at every boundary where somebody was reading.

  A string is itself; a fiber is its last value; a dictionary with a
  `:message` (or `:msg`, or `:error`) hands that over; any other value
  is printed as data (`%q`) rather than as an address, because
  `{:void.http/timeout true}` is a sentence and its pointer is not.
  Long output is cut — a report nobody can read past is the thing being
  fixed here.``
  [e &opt limit]
  (default limit 500)
  (defn cut [s]
    (if (> (length s) limit) (string (string/slice s 0 (- limit 3)) "...") s))
  (cond
    (or (string? e) (buffer? e)) (cut (string e))
    (fiber? e) (message-of (fiber/last-value e) limit)
    (dictionary? e)
    (if-let [m (some |(let [v (get e $)] (when (or (string? v) (buffer? v)) v))
                     error-message-keys)]
      (cut (string m))
      (cut (string/format "%q" e)))
    (indexed? e) (cut (string/format "%q" e))
    (cut (describe e))))

# -- redaction and serializers -------------------------------------------

(defn- redact [rec]
  (each path (state :redact)
    (unless (nil? (get-in rec path))
      (put-in rec path "[redacted]")))
  rec)

(defn- serialize [rec]
  (def sers (state :serializers))
  (unless (empty? sers)
    (eachp [k f] sers
      (def v (get rec k))
      (unless (nil? v)
        (def [ok out] (protect (f v)))
        (put rec k (if ok out (string/format "<serializer error: %s>"
                                             (if (string? out) out (describe out))))))))
  rec)

(def err-serializer
  "The default :err serializer: an error value or a fiber ->
  {:msg :stacktrace?}. The message is `message-of`'s, so a structured
  throw logs what it says rather than where it lives."
  (fn err-ser [e]
    (cond
      (fiber? e)
      {:msg (message-of (fiber/last-value e))
       :stacktrace (string/trim
                     (with-dyns [:err @""]
                       (debug/stacktrace e (fiber/last-value e) "")
                       (string (dyn :err))))}
      {:msg (message-of e)})))

# -- sinks ---------------------------------------------------------------

(def- level-names
  {10 "TRACE" 20 "DEBUG" 30 "INFO " 40 "WARN " 50 "ERROR" 60 "FATAL"})

(def- level-colors
  {10 "90" 20 "36" 30 "32" 40 "33" 50 "31" 60 "35"})

(defn- fmt-ts [ts]
  (def d (os/date (math/floor ts) true))
  (string/format "%02d:%02d:%02d" (d :hours) (d :minutes) (d :seconds)))

(defn- kv-str [rec]
  (def parts @[])
  (each k (sorted (filter |(not (in {:ts true :level true :ns true :msg true} $))
                          (keys rec)))
    (array/push parts (string/format "%s=%j" (string k) (rec k))))
  (if (empty? parts) "" (string " " (string/join parts " "))))

(defn pretty-sink
  "Synchronous human sink: one colored line per record to stderr
  (colors only on a tty)."
  [&opt opts]
  (def color?
    (if (nil? (get opts :color))
      (let [[ok tty] (protect (os/isatty stderr))] (and ok tty))
      (get opts :color)))
  (fn pretty [rec]
    (def n (level-num (rec :level)))
    (def lvl (get level-names n "?????"))
    (eprintf "%s %s %s — %s%s"
             (fmt-ts (rec :ts))
             (if color? (string "\e[" (get level-colors n "0") "m" lvl "\e[0m") lvl)
             (rec :ns) (rec :msg) (kv-str rec))))

(defn jdn-sink
  ``Production sink: JDN lines (janet %j — machine-parseable, JSON-ish
  for plain data) written by a dedicated fiber behind a buffered
  channel. A full buffer drops the record and counts it —
  (log/dropped) — instead of back-pressuring request fibers; :fatal
  records are written synchronously. The writer fiber is registered in
  the module closer list — (log/close!) shuts it down (plugin/shutdown!
  calls that, so a stopped app does not leave the loop alive).``
  [&opt opts]
  (def cap (get opts :buffer 1024))
  (def out (get opts :stream stderr))
  (def chan (ev/chan cap))
  (defn write! [rec]
    (xprintf out "%j" rec))
  (ev/go (fn jdn-writer []
           # batch whatever queued into one write — fewer syscalls
           # under load, still line-per-record output
           (def acc @"")
           (var run true)
           (while run
             (def rec (ev/take chan))
             (if (= :void.core.log/close rec)
               (set run false)
               (do
                 (buffer/format acc "%j\n" rec)
                 (while (and run (pos? (ev/count chan)) (< (length acc) 65536))
                   (def more (ev/take chan))
                   (if (= :void.core.log/close more)
                     (set run false)
                     (buffer/format acc "%j\n" more)))
                 (protect (xprin out acc))
                 (buffer/clear acc))))))
  (array/push (state :closers) (fn close-jdn [] (ev/give chan :void.core.log/close)))
  (fn jdn [rec]
    (if (= 60 (level-num (rec :level)))
      (write! rec)                       # fatal: no buffering, no loss
      (if (ev/full chan)
        (put state :dropped (inc (state :dropped)))
        (ev/give chan rec)))))

(defn dropped
  "Records dropped by full async sink buffers since startup."
  []
  (state :dropped))

(def- default-sinks [(pretty-sink)])

(defn close!
  "Shut down async sink writers (jdn-sink fibers). Called by
  plugin/shutdown!; safe to call twice."
  []
  (each c (state :closers) (protect (c)))
  (array/clear (state :closers))
  nil)

(defn set-sinks!
  "Replace the active sinks (tuple/array of (fn [record])). nil
  restores the default pretty stderr sink. Close previous async
  writers with (log/close!) BEFORE constructing replacements —
  configure! does this."
  [sinks]
  (put state :sinks sinks))

(defn sinks
  "The active sink list (the default pretty sink when none set)."
  []
  (or (state :sinks) default-sinks))

(defn set-serializers!
  "Replace the serializer table (key -> fn). The :err serializer is
  merged in unless overridden."
  [sers]
  (put state :serializers (merge {:err err-serializer} (or sers {}))))

(defn set-redact!
  "Replace the redaction paths ([[:password] [:user :token] ...])."
  [paths]
  (put state :redact (or paths [])))

(set-serializers! {})

# -- emission ------------------------------------------------------------

(defn emit
  "Assemble and dispatch one record — the macros call this after the
  level check. kvs are key-value pairs."
  [ns level msg & kvs]
  (def rec @{:ts (os/clock :realtime) :level level :ns ns :msg msg})
  (eachp [k v] (context) (put rec k v))
  (when (odd? (length kvs))
    (errorf "log: expected key-value pairs after the message, got %d args" (length kvs)))
  (var i 0)
  (while (< i (length kvs))
    (put rec (kvs i) (kvs (inc i)))
    (+= i 2))
  (redact (serialize rec))
  (each sink (or (state :sinks) default-sinks)
    (protect (sink rec)))
  nil)

(defn ns-from-file
  "Derive a dotted log namespace from a source path: strip the
  extension, dots for slashes, leading ./ and / trimmed."
  [file]
  (def s (string file))
  (def no-ext (if (string/has-suffix? ".janet" s)
               (string/slice s 0 (- (length s) 6))
               s))
  (string/join
    (filter |(not (or (empty? $) (= "." $) (= ".." $)))
            (string/split "/" no-ext))
    "."))

(defmacro- deflevel [name level]
  ~(defmacro ,name
     ,(string "Log at :" name " — `(log/" name " \"msg\" :k v ...)`. "
              "Arguments are NOT evaluated when the level is off for "
              "this namespace (derived from the defining file; override "
              "by passing :ns <string> first).")
     [msg & kvs]
     (def [ns rest]
       (if (= :ns (first kvs))
         [(in kvs 1) (tuple/slice kvs 2)]
         [(,ns-from-file (or (dyn :current-file) "?")) kvs]))
     ~(when (,',enabled? ,ns ,',level)
        (,',emit ,ns ,',level ,msg ,;rest))))

# `error` deliberately shadows the core error in this module from here
# on — every core-error use above this line is errorf/protect
(deflevel trace :trace)
(deflevel debug :debug)
(deflevel info :info)
(deflevel warn :warn)
(deflevel error :error)
(deflevel fatal :fatal)

# -- configuration (bootstrap wires this from [:log]) --------------------

(def Config
  "Schema of the [:log] config slice (validated by plugin/start!)."
  {:level [:optional [:enum :trace :debug :info :warn :error :fatal]]
   :levels [:optional :dictionary]
   :sink [:optional [:enum :pretty :jdn]]
   :redact [:optional [:vector [:vector :keyword]]]
   :buffer [:optional [:int {:min 1}]]})

(defn configure!
  ``Apply the [:log] config slice for a profile: root/per-ns levels,
  redaction, and the built-in sink — :pretty (default for :dev/:test)
  or :jdn (default for any other profile). Contributed sinks and
  serializers are installed separately (plugin/start!).``
  [cfg profile]
  (def c (or cfg {}))
  (put state :root (level-num (get c :level root-default)))
  (put state :tree @{})
  (table/clear (state :memo))
  (eachp [ns l] (get c :levels {})
    (set-level! (string ns) l))
  (set-redact! (get c :redact []))
  (def sink-name
    (or (c :sink)
        (if (in {:dev true :test true} profile) :pretty :jdn)))
  (close!)                               # stop previous async writers
  (set-sinks!
    [(case sink-name
       :pretty (pretty-sink)
       :jdn (jdn-sink {:buffer (get c :buffer 1024)}))])
  sink-name)
