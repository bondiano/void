### void/jobs/job — what a job *is*: the definition registry, `defjob`,
### and the options a definition carries (SPEC.md §5.12, ADR-0012,
### ROADMAP 2.4).
###
### A job definition is a name, a handler and a policy. The name is a
### keyword and it is what travels: a queued job is `{:job :welcome-mail
### :args [42]}` in a table, in redis or in a row, and the process that
### runs it looks the name up in this registry. Which is also why the
### handler is held as a *binding*, not as a function value (ADR-0002):
### the environment of the defining module plus the symbol, read at
### call time, so redefining the function in the REPL — or a reload by
### void/dev's watcher — is live for jobs already queued. void/http's
### symbol handlers resolve the same way and for the same reason.
###
### The policy is everything the runtime needs to decide what to do
### when the handler throws or when two enqueues collide: how many
### attempts, how long to wait between them, which queue, how urgent,
### whether a second copy of the same work should be queued at all, and
### which group it belongs to for fair scheduling. All of it has a
### default from the [:jobs] config slice, and all of it can be
### overridden per enqueue — the definition is where the policy
### *belongs*, not where it is locked.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

# -- canonical rendering -------------------------------------------------
#
# The same problem void/cache/key exists for, and the same answer.
# Janet prints dictionary keys in hash order, which is stable within a
# process and nowhere else; a unique key rendered with %j would let two
# processes disagree about whether they are enqueueing the same work —
# and a uniqueness check that silently stops being one is worse than no
# uniqueness at all. So: dictionary pairs sorted, everything tagged by
# type so that "1" and 1 cannot collide.

(defn canonical
  ``A deterministic string rendering of a value: dictionary pairs
  sorted by their own rendering, every scalar tagged with its type.
  The same value renders the same way in every process, which is what
  a unique key across processes needs.``
  [v]
  (cond
    (nil? v) "n"
    (boolean? v) (if v "b:t" "b:f")
    (number? v) (string/format "d:%.17g" v)
    (string? v) (string "s:" (length v) ":" v)
    (buffer? v) (string "s:" (length v) ":" v)
    (keyword? v) (string "k:" v)
    (symbol? v) (string "y:" v)
    (dictionary? v)
    (string "m{"
            (string/join
              (sorted (seq [k :keys v] (string (canonical k) "=" (canonical (get v k)))))
              ",")
            "}")
    (indexed? v)
    (string "v[" (string/join (map canonical v) ",") "]")
    (errorf "cannot render %q into a job key — args and unique keys must be plain data" v)))

# -- backoff -------------------------------------------------------------

(def strategies
  "Retry backoff strategies: :fixed (always :base), :linear (:base per
  attempt) and :exponential (:base doubling per attempt)."
  [:fixed :linear :exponential])

(def default-backoff
  ``The default retry policy. Exponential from a second, capped at an
  hour, with half of the delay turned into jitter — a thousand jobs
  failing on the same outage must not come back in the same instant,
  which is how a struggling dependency is turned into a dead one.``
  {:strategy :exponential :base 1 :max 3600 :jitter 0.5})

(defn normalize-backoff
  "Validate and complete a backoff policy against `default-backoff`."
  [b0 &opt who]
  (default who "backoff")
  (def b (merge default-backoff (or b0 {})))
  (unless (index-of (b :strategy) strategies)
    (errorf "%s: :strategy must be one of %s, got %q"
            who (names-str strategies) (b :strategy)))
  (each k [:base :max]
    (def v (b k))
    (unless (and (number? v) (>= v 0))
      (errorf "%s: %q must be a non-negative number, got %q" who k v)))
  (def j (b :jitter))
  (unless (and (number? j) (>= j 0) (<= j 1))
    (errorf "%s: :jitter must be a number between 0 and 1, got %q" who j))
  (freeze b))

(defn retry-delay
  ``Seconds to wait before attempt `attempt` + 1, given that `attempt`
  has just failed (1-based). The undelayed delay is :base for :fixed,
  :base × attempt for :linear and :base × 2^(attempt-1) for
  :exponential, capped at :max; :jitter then spreads the result
  uniformly over [(1 - jitter) × d, d], so `:jitter 0` is exactly
  reproducible and `:jitter 1` is the full-jitter spelling.``
  [backoff attempt &opt rand]
  (default rand math/random)
  (def b (or backoff default-backoff))
  (def n (max 1 attempt))
  (def raw
    (case (b :strategy)
      :fixed (b :base)
      :linear (* (b :base) n)
      (* (b :base) (math/pow 2 (dec n)))))
  (def capped (min (b :max) raw))
  (def j (b :jitter))
  (if (zero? j)
    capped
    (* capped (- 1 (* j (rand))))))

# -- definitions ---------------------------------------------------------

(def- allowed-opts
  {:queue true :priority true :max-attempts true :backoff true
   :timeout true :unique true :unique-ttl true :group true})

(def unique-modes
  ``How a job's unique key is derived: :args — one job per (name,
  arguments) pair; :job — one job of this name at a time, whatever the
  arguments. A string is used as the key literally (after the job's
  name, so two jobs cannot collide by choosing the same word). Every
  form holds until the job finishes, or — with :unique-ttl — for that
  many seconds.``
  [:args :job])

(defn normalize-opts
  ``Validate the policy of a job definition (or the per-enqueue
  overrides, which take the same keys). Values left out are decided by
  the [:jobs] config slice at enqueue time, so this fills nothing in —
  it only refuses what cannot be meant.``
  [who opts0]
  (def opts (or opts0 {}))
  (unless (dictionary? opts)
    (errorf "%s: options must be a dictionary, got %q" who opts))
  (eachk k opts
    (unless (in allowed-opts k)
      (errorf "%s: unknown option %q (allowed: %s)"
              who k (names-str (keys allowed-opts)))))
  (when-let [q (get opts :queue)]
    (unless (keyword? q)
      (errorf "%s: :queue must be a keyword, got %q" who q)))
  (when-let [p (get opts :priority)]
    (unless (and (number? p) (= p (math/trunc p)))
      (errorf "%s: :priority must be an integer (lower runs first), got %q" who p)))
  (when-let [n (get opts :max-attempts)]
    (unless (and (number? n) (= n (math/trunc n)) (>= n 1))
      (errorf "%s: :max-attempts must be an integer >= 1, got %q" who n)))
  (when-let [t (get opts :timeout)]
    (unless (and (number? t) (pos? t))
      (errorf "%s: :timeout must be a positive number of seconds, got %q" who t)))
  (when-let [u (get opts :unique)]
    # a keyword that is not a mode is a typo, not a key: :arg would
    # otherwise become a perfectly valid literal meaning something
    # nobody wrote down. A literal key is a string
    (unless (or (index-of u unique-modes) (string? u))
      (errorf "%s: :unique must be %s, or a literal key as a string, got %q"
              who (names-str unique-modes) u)))
  (when-let [t (get opts :unique-ttl)]
    (unless (and (number? t) (pos? t))
      (errorf "%s: :unique-ttl must be a positive number of seconds, got %q" who t)))
  (when-let [g (get opts :group)]
    (unless (or (string? g) (keyword? g) (callable? g))
      (errorf "%s: :group must be a string, a keyword or a function of the job's arguments, got %q"
              who g)))
  (def out (table ;(kvs opts)))
  (when (in opts :backoff)
    (put out :backoff (normalize-backoff (opts :backoff) (string who " :backoff"))))
  (table/to-struct out))

(def registry
  ``Job definitions by name. Global on purpose: a job name is what
  travels between processes, so the process claiming a job has to be
  able to find the handler without the enqueueing one telling it
  where. Redefining a name replaces the definition — REPL-friendly,
  and the reason a reloaded module does not need a restart.``
  @{})

(defn define!
  ``Register a job definition (the runtime half of `defjob`).

    (job/define! :welcome-mail {:queue :mail}
                 {:env (curenv) :binding 'welcome-mail :doc "..."})

  The handler is named either by :binding + :env — the late-binding
  form, read again on every run — or by :fn, a function value, which
  is what a job defined at the REPL or built by a factory gets and
  which does not survive a reload.``
  [name opts binding]
  (unless (keyword? name)
    (errorf "job name must be a keyword, got %q" name))
  (def who (string/format "job %q" name))
  (def o (normalize-opts who opts))
  (unless (dictionary? binding)
    (errorf "%s: expected {:env ... :binding ...} or {:fn ...}, got %q" who binding))
  (def f (get binding :fn))
  (def sym (get binding :binding))
  (when f
    (unless (callable? f)
      (errorf "%s: :fn must be a function, got %q" who f)))
  (when sym
    (unless (dictionary? (get binding :env))
      (errorf "%s: :binding %q needs the :env it lives in" who sym)))
  (unless (or f sym)
    (errorf "%s: a definition needs :fn or :binding + :env" who))
  # shallow, deliberately: :env is the defining module's environment,
  # a table that refers to itself through its own bindings, and a deep
  # copy of it is a walk that does not end
  (def d
    (table/to-struct
      @{:name name
        :opts o
        :fn f
        :binding sym
        :env (get binding :env)
        :doc (get binding :doc)}))
  (put registry name d)
  d)

(defn lookup
  "The definition registered under `name`, or nil."
  [name]
  (get registry name))

(defn lookup!
  "The definition registered under `name`; throws naming what is
  registered when there is none — a job whose module the worker never
  imported is the most common way a queue stalls."
  [name]
  (or (get registry name)
      (errorf "no job named %q is defined in this process (defined: %s) — the worker must import the module that declares it"
              name (names-str (keys registry)))))

(defn defined
  "Names of every registered job definition."
  []
  (sorted (keys registry)))

(defn forget!
  "Drop a definition — for tests, and for a REPL that renamed one."
  [name]
  (put registry name nil))

(defn handler
  ``The function behind a definition, resolved now rather than when it
  was declared: a `defjob` whose module has been reloaded runs the new
  body, and one whose binding has stopped being a function says so
  here instead of in the middle of a queue.

  The module binding wins over the value captured at definition time,
  which is what makes a reload live. The captured value is the
  fallback for a job defined somewhere a module binding cannot exist —
  inside a function, in a test, at the REPL — and such a job is not
  hot-reloadable, which is the whole difference between the two.``
  [d]
  (def b (when (and (d :env) (d :binding)) (get (d :env) (d :binding))))
  (cond
    (and b (callable? (get b :value))) (b :value)
    (callable? (d :fn)) (d :fn)
    (errorf "job %q: %q no longer names a function in its module — was it renamed?"
            (d :name) (d :binding))))

(defn unique-key
  ``The uniqueness key of a call, or nil when the job does not ask for
  one. :args keys by name and arguments, :job by name alone, and a
  literal string or keyword is used as written — after the name, so
  two jobs cannot collide by choosing the same word.``
  [d args opts]
  (def mode (or (get opts :unique) (get-in d [:opts :unique])))
  (cond
    (nil? mode) nil
    (= :job mode) (string (d :name))
    (= :args mode) (string (d :name) "/" (canonical (tuple ;args)))
    (string (d :name) "/" mode)))

(defn group-key
  ``The fair-scheduling group of a call: what the enqueue named, else
  what the definition declares — a literal, or a function of the
  job's arguments, which is where a tenant id usually lives.``
  [d args opts]
  (def g (if (in opts :group) (get opts :group) (get-in d [:opts :group])))
  (cond
    (nil? g) nil
    (callable? g) (let [k (g ;args)] (when k (string k)))
    (string g)))

# -- the macro -----------------------------------------------------------

(defn defjob-form
  ``The expansion of `defjob`, as a function — so that the macro can
  exist both here and on `void/jobs` (which is what applications
  import) without being written twice. `more` is everything after the
  name: an optional docstring, an optional options map, the parameter
  list, then the body.``
  [name more]
  (var rest more)
  (var doc nil)
  (when (string? (first rest))
    (set doc (first rest))
    (set rest (tuple ;(drop 1 rest))))
  (var opts nil)
  (when (and (dictionary? (first rest)) (not (indexed? (first rest))))
    (set opts (first rest))
    (set rest (tuple ;(drop 1 rest))))
  (def params (first rest))
  (unless (and (indexed? params) (all symbol? params))
    (errorf "defjob %q: expected a parameter list after the name%s, got %q"
            name (if doc " and docstring" "") params))
  (def body (drop 1 rest))
  # both halves of the handler are recorded: the binding, which is what
  # a reload updates, and the value, which is the only thing there is
  # when `defjob` is not at a module's top level
  ~(upscope
     (defn ,name ,;(if doc [doc] []) ,params ,;body)
     (,define! ,(keyword name) ,opts
               {:env (,curenv) :binding ',name :fn ,name :doc ,doc})))

(defmacro defjob
  ``Define a job — a function, plus the policy for running it in the
  background:

      (jobs/defjob welcome-mail
        "Send the welcome mail."
        {:queue :mail :max-attempts 5 :timeout 30 :unique :args}
        [user-id]
        (mail/send (users/find user-id) :welcome))

      (jobs/enqueue :welcome-mail 42)

  The docstring and the options map are both optional and both come
  before the parameter list, exactly where `defn` would put the
  docstring. The name of the job is the name of the function as a
  keyword, and the function stays an ordinary function — calling it
  directly runs the work inline, which is what a test usually wants.

  Options: :queue :priority :max-attempts :backoff :timeout :unique
  :unique-ttl :group — see `normalize-opts`; anything left out is
  decided by the [:jobs] config slice.

  Declare jobs at the top level of a module. One declared inside a
  function still works, but its handler is then the function value
  captured right there rather than a module binding, so a reload does
  not reach it (see `handler`).``
  [name & more]
  (defjob-form name more))
