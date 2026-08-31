### void/kafka/librdkafka — the librdkafka surface this plugin uses,
### and nothing more (ADR-0035, SPEC.md §5.11, ROADMAP 5).
###
### The shape is void/db-mysql/libmysql's: the library path is
### configuration ([:kafka :library]) rather than a compile-time
### constant, and a package that merely gets loaded — `plugin/dry-run`
### in CI, `void routes` on a laptop with no Kafka — must not explode
### on import. Until `load!` runs, every binding is nil and
### `available?` says so.
###
### Unlike libmysqlclient, everything here is called from ONE VM — the
### loop's. librdkafka runs its own threads regardless (one per broker
### plus internals), but they never call us: the only surface we use
### is the event API, where the library parks its news on a queue and
### `rd_kafka_queue_poll` with timeout 0 hands it over without ever
### blocking (ADR-0035). The one hole a thread could crawl through —
### the logger callback — is closed by routing logs to a queue too
### (`log.queue`), where they come out as ordinary events.
###
### Two structs are read by offset, and both are a different bargain
### from ADR-0033's MYSQL_FIELD:
###
###   * `rd_kafka_message_t` is documented public ABI, unchanged since
###     0.8 — the header declares it in the open, applications iterate
###     arrays of it.
###   * `rd_kafka_vu_t` (what `rd_kafka_produceva` takes) pads its own
###     union to 64 bytes with a comment saying why: "Padding size for
###     future-proofness". The layout is the library's promise, not
###     our guess.
###
### The third struct, `rd_kafka_topic_partition_t`, is avoided
### entirely: offsets are stored with `rd_kafka_offset_store`, which
### takes the three values as arguments.

# -- where the library lives ---------------------------------------------

(def default-candidates
  ``Where librdkafka is looked for when nothing is configured, in
  order. A bare name goes through the dynamic loader's own search
  path; the absolute ones are the usual keg locations, which are not
  on it — Homebrew keeps its lib/ out of DYLD's way.``
  (case (os/which)
    :macos ["librdkafka.dylib"
            "/opt/homebrew/opt/librdkafka/lib/librdkafka.dylib"
            "/usr/local/opt/librdkafka/lib/librdkafka.dylib"]
    :windows ["librdkafka.dll"]
    ["librdkafka.so.1" "librdkafka.so"]))

(def path-env
  "Environment variable that overrides the search — an escape hatch
  for a machine where the library lives somewhere unusual and editing
  the config is not an option."
  "VOID_LIBRDKAFKA")

# -- bindings ------------------------------------------------------------

(def- registry
  "Every declared binding: {:symbol :ret :args :optional :install}."
  @[])

(defmacro- defrk
  ``Declare one librdkafka function: a module-level `var`, nil until
  `load!` installs the call. `& args` are ffi types; a trailing
  :optional marks a symbol an older library may not have.``
  [sym ret & args]
  (def optional (truthy? (index-of :optional args)))
  (def types (filter |(not= :optional $) args))
  ~(upscope
     (var ,sym nil)
     # `registry`, not `,registry`: unquoting an array splices a fresh
     # literal per evaluation (see void/db-mysql/libmysql for the long
     # form of this comment)
     (array/push registry
                 {:symbol ,(string sym)
                  :ret ,ret
                  :args [,;types]
                  :optional ,optional
                  :install (fn [f] (set ,sym f))})))

# library
(defrk rd_kafka_version_str :string)
(defrk rd_kafka_err2str :string :int)

# configuration. conf_set copies name and value, and a conf that
# reached rd_kafka_new is owned by the client from then on
(defrk rd_kafka_conf_new :ptr)
(defrk rd_kafka_conf_destroy :void :ptr)
(defrk rd_kafka_conf_set :int :ptr :string :string :ptr :ulong)
(defrk rd_kafka_conf_set_events :void :ptr :int)

# client lifecycle. rd_kafka_new takes ownership of the conf on
# success only; rd_kafka_destroy joins the library's threads — the one
# deliberately blocking call, made at :stop (ADR-0035)
(defrk rd_kafka_new :ptr :int :ptr :ptr :ulong)
(defrk rd_kafka_destroy :void :ptr)
(defrk rd_kafka_name :string :ptr)
(defrk rd_kafka_outq_len :int :ptr)

# event queues — the whole integration (ADR-0035): poll with timeout 0
# never blocks, io_event_enable writes a byte to OUR fd on the
# empty→non-empty transition, and void/fdwait sleeps on that
(defrk rd_kafka_queue_get_main :ptr :ptr)
(defrk rd_kafka_set_log_queue :int :ptr :ptr)
(defrk rd_kafka_queue_get_consumer :ptr :ptr)
(defrk rd_kafka_queue_destroy :void :ptr)
(defrk rd_kafka_queue_io_event_enable :void :ptr :int :ptr :ulong)
(defrk rd_kafka_queue_poll :ptr :ptr :int)

# events
(defrk rd_kafka_event_type :int :ptr)
(defrk rd_kafka_event_destroy :void :ptr)
(defrk rd_kafka_event_error :int :ptr)
# :ptr, not :string — NULL for an event that carries no error, and
# janet's ffi reads a :string return straight off the pointer
(defrk rd_kafka_event_error_string :ptr :ptr)
(defrk rd_kafka_event_message_next :ptr :ptr)
(defrk rd_kafka_event_message_count :ulong :ptr)
# the library's own log lines as events — what keeps its threads from
# writing to stderr past void/core/log (out-parameters: facility,
# text, syslog level)
(defrk rd_kafka_event_log :int :ptr :ptr :ptr :ptr)

# producing. produceva is producev without the varargs: an ARRAY of
# rd_kafka_vu_t, which is what a binding can build (a variadic call
# through ffi/ is not portable — on darwin/aarch64 variadic arguments
# go on the stack while a fixed signature puts them in registers)
(defrk rd_kafka_produceva :ptr :ptr :ptr :ulong)

# rd_kafka_error_t — returned by produceva and consumer_close_queue.
# :string is safe on error_string: it is only called on a non-NULL
# error, and the library documents it non-NULL there
(defrk rd_kafka_error_code :int :ptr)
(defrk rd_kafka_error_string :string :ptr)
(defrk rd_kafka_error_destroy :void :ptr)

# consuming
(defrk rd_kafka_poll_set_consumer :int :ptr)
(defrk rd_kafka_subscribe :int :ptr :ptr)
(defrk rd_kafka_unsubscribe :int :ptr)
(defrk rd_kafka_topic_partition_list_new :ptr :int)
(defrk rd_kafka_topic_partition_list_add :ptr :ptr :string :int)
(defrk rd_kafka_topic_partition_list_destroy :void :ptr)
(defrk rd_kafka_offset_store :int :ptr :int :int64)
(defrk rd_kafka_topic_name :string :ptr)
# the async half of consumer close (librdkafka >= 1.9); without it the
# blocking rd_kafka_consumer_close is the :stop-time fallback
(defrk rd_kafka_consumer_close_queue :ptr :ptr :ptr :optional)
(defrk rd_kafka_consumer_closed :int :ptr :optional)
(defrk rd_kafka_consumer_close :int :ptr)

# headers of a fetched message. get_all's out-parameters are written
# into caller buffers; ERR__NOENT ends the iteration
(defrk rd_kafka_message_headers :int :ptr :ptr)
(defrk rd_kafka_header_get_all :int :ptr :ulong :ptr :ptr :ptr)

# the boot probe (ADR-0035): DescribeCluster through the same event
# API — an admin request whose answer is an event, so the boot check
# parks instead of blocking. The symbols appeared in librdkafka 2.3;
# on an older library the probe is skipped and says so
(defrk rd_kafka_AdminOptions_new :ptr :ptr :int :optional)
(defrk rd_kafka_AdminOptions_destroy :void :ptr :optional)
(defrk rd_kafka_AdminOptions_set_request_timeout :int :ptr :int :ptr :ulong :optional)
(defrk rd_kafka_DescribeCluster :void :ptr :ptr :ptr :optional)

# -- libc: the pipe the library wakes us through -------------------------
#
# A janet stream will not surrender its descriptor, and the descriptor
# is the whole point here: librdkafka writes into one end, void/fdwait
# sleeps on the other. So the pipe is made the C way. The bindings are
# installed by the same load! that opens librdkafka — from the process
# itself, which always has them.

(var pipe- nil)
(var read- nil)
(var write- nil)
(var close- nil)

# -- constants -----------------------------------------------------------

(def RD-KAFKA-PRODUCER 0)
(def RD-KAFKA-CONSUMER 1)

(def CONF-OK 0)

(def events
  "The rd_kafka_event_type_t values this plugin dispatches on."
  {:dr 0x1
   :fetch 0x2
   :log 0x4
   :error 0x8
   :rebalance 0x10
   :offset-commit 0x20
   :stats 0x40
   :describe-cluster-result 0x200000})

(def MSG-F-COPY
  "produceva msgflag: the library copies the payload during the call —
  which is what lets a janet string be handed over without a thought
  about who frees it."
  0x2)

(def vtypes
  "rd_kafka_vtype_t, in enum order."
  {:end 0 :topic 1 :rkt 2 :partition 3 :value 4 :key 5
   :opaque 6 :msgflags 7 :timestamp 8 :header 9 :headers 10})

(def ADMIN-OP-DESCRIBECLUSTER 20)

(def error-codes
  "The rd_kafka_resp_err_t values this plugin branches on. Internal
  errors (the library about itself) are negative; broker errors are
  positive; 0 is no error."
  {:no-error 0
   :msg-timed-out -192      # RD_KAFKA_RESP_ERR__MSG_TIMED_OUT
   :partition-eof -191      # RD_KAFKA_RESP_ERR__PARTITION_EOF
   :all-brokers-down -187   # RD_KAFKA_RESP_ERR__ALL_BROKERS_DOWN
   :timed-out -185          # RD_KAFKA_RESP_ERR__TIMED_OUT
   :noent -156              # RD_KAFKA_RESP_ERR__NOENT
   :fatal -150})            # RD_KAFKA_RESP_ERR__FATAL

(def PARTITION-UA
  "RD_KAFKA_PARTITION_UA — let the partitioner choose."
  -1)

# -- pointer helpers -----------------------------------------------------

(def- cell-size 8)

(defn cstr
  "A `char *` that may be NULL, as a janet string or nil."
  [ptr]
  (when ptr
    (def cell (buffer/new-filled cell-size))
    (ffi/write :ptr ptr cell 0)
    (ffi/read :string cell 0)))

(defn bytes-at
  ``Exactly `n` bytes from `ptr`, as a janet string. A message value
  is a pointer plus a length, and the length is the half that matters:
  a payload is bytes, and bytes are allowed to contain a NUL.``
  [ptr n]
  (if (or (nil? ptr) (zero? n))
    ""
    (string (ffi/pointer-buffer ptr n n 0))))

(defn read-out
  "One out-parameter of C type `type`, read back from an 8-byte cell."
  [cell type]
  (ffi/read type cell 0))

(defn out-cell
  "An 8-byte zeroed buffer for a C out-parameter."
  []
  (buffer/new-filled cell-size))

# -- rd_kafka_message_t --------------------------------------------------
#
# Documented public ABI, stable since 0.8 (LP64):
#
#     0  rd_kafka_resp_err_t err     8  rd_kafka_topic_t *rkt
#    16  int32_t partition          24  void *payload
#    32  size_t len                 40  void *key
#    48  size_t key_len             56  int64_t offset
#    64  void *_private
#
# _private is the msg_opaque of a delivery report — where the u64
# token `produce!` wrote comes back out (./producer).

(def- message-size 72)

(def message-offsets
  "Where the values this plugin reads live in an rd_kafka_message_t."
  {:err 0 :rkt 8 :partition 16 :payload 24 :len 32
   :key 40 :key-len 48 :offset 56 :private 64})

(defn message
  ``One rd_kafka_message_t as a table. `:topic` is read through
  `rd_kafka_topic_name`, whose lifetime is the rkt's — the string is
  copied here, so the table survives the event that owned it. `:len`
  and `:key-len` go through `string` + `scan-number` for the same
  reason every driver does it: the ffi hands a :ulong back as a
  core/u64, and a length has to be a number that indexes.``
  [ptr]
  (when ptr
    (def buf (ffi/pointer-buffer ptr message-size message-size 0))
    (def payload (ffi/read :ptr buf (message-offsets :payload)))
    (def len (scan-number (string (ffi/read :ulong buf (message-offsets :len)))))
    (def key (ffi/read :ptr buf (message-offsets :key)))
    (def key-len (scan-number (string (ffi/read :ulong buf (message-offsets :key-len)))))
    (def rkt (ffi/read :ptr buf (message-offsets :rkt)))
    {:err (ffi/read :int buf (message-offsets :err))
     :rkt rkt
     :topic (when rkt (rd_kafka_topic_name rkt))
     :partition (ffi/read :int32 buf (message-offsets :partition))
     :value (bytes-at payload len)
     :key (when key (bytes-at key key-len))
     # numbers, not the core/s64 and core/u64 the ffi hands back: the
     # offset is compared and printed, and the token is a table key —
     # and a core/u64 42 is not equal to the number 42 that minted it.
     # Both stay far below 2^53
     :offset (scan-number (string (ffi/read :int64 buf (message-offsets :offset))))
     :token (scan-number (string (ffi/read :uint64 buf (message-offsets :private))))}))

(defn event-log
  "A log event's {:fac :text :level} — syslog levels, 3 is an error,
  7 is debug."
  [ev]
  (def facp (out-cell))
  (def strp (out-cell))
  (def levelp (out-cell))
  (when (zero? (rd_kafka_event_log ev facp strp levelp))
    {:fac (cstr (read-out facp :ptr))
     :text (cstr (read-out strp :ptr))
     :level (read-out levelp :int)}))

(defn message-headers
  ``The headers of a fetched message, as a table of string -> string.
  The headers object belongs to the message and the message to its
  event, so everything is copied on the way out. A message without
  headers is {} — ERR__NOENT from either call is an answer, not an
  error.``
  [msg-ptr]
  (def out @{})
  (def hdrsp (out-cell))
  (when (zero? (rd_kafka_message_headers msg-ptr hdrsp))
    (def hdrs (read-out hdrsp :ptr))
    (when hdrs
      (def namep (out-cell))
      (def valp (out-cell))
      (def sizep (out-cell))
      (var idx 0)
      (while (zero? (rd_kafka_header_get_all hdrs idx namep valp sizep))
        (def name (cstr (read-out namep :ptr)))
        (def val (read-out valp :ptr))
        (def size (scan-number (string (read-out sizep :ulong))))
        (when name
          # a NULL header value is a real thing on the wire; it arrives
          # as nil, distinct from ""
          (put out name (when val (bytes-at val size))))
        (++ idx))))
  out)

# -- rd_kafka_vu_t -------------------------------------------------------
#
# What produceva takes: vtype at 0, the union at 8, and the union
# padded by the header itself to 64 bytes ("Padding size for
# future-proofness") — so the stride is 72 and the layout is the
# library's promise (ADR-0035).

(def vu-size 72)
(def- vu-union 8)

(defn vu-buffer
  "A zeroed buffer for `n` rd_kafka_vu_t entries."
  [n]
  (buffer/new-filled (* n vu-size)))

(defn- vu-base [i] (* i vu-size))

(defn vu-topic! [buf i name]
  (ffi/write :int (vtypes :topic) buf (vu-base i))
  (ffi/write :ptr name buf (+ (vu-base i) vu-union)))

(defn vu-value! [buf i bytes]
  (ffi/write :int (vtypes :value) buf (vu-base i))
  (ffi/write :ptr bytes buf (+ (vu-base i) vu-union))
  (ffi/write :uint64 (length bytes) buf (+ (vu-base i) vu-union 8)))

(defn vu-key! [buf i bytes]
  (ffi/write :int (vtypes :key) buf (vu-base i))
  (ffi/write :ptr bytes buf (+ (vu-base i) vu-union))
  (ffi/write :uint64 (length bytes) buf (+ (vu-base i) vu-union 8)))

(defn vu-msgflags! [buf i flags]
  (ffi/write :int (vtypes :msgflags) buf (vu-base i))
  (ffi/write :int flags buf (+ (vu-base i) vu-union)))

(defn vu-opaque!
  "The msg_opaque as a u64 written where the `void *` goes: the
  pointer is never dereferenced by anyone — it rides to the delivery
  report and comes back out of `_private` as the same number."
  [buf i token]
  (ffi/write :int (vtypes :opaque) buf (vu-base i))
  (ffi/write :uint64 token buf (+ (vu-base i) vu-union)))

(defn vu-header! [buf i name bytes]
  (ffi/write :int (vtypes :header) buf (vu-base i))
  (ffi/write :ptr name buf (+ (vu-base i) vu-union))
  (ffi/write :ptr bytes buf (+ (vu-base i) vu-union 8))
  (ffi/write :int64 (length bytes) buf (+ (vu-base i) vu-union 16)))

# -- the pipe ------------------------------------------------------------

(defn make-pipe
  ``A pipe(2) as [read-fd write-fd]. The write end goes to
  `rd_kafka_queue_io_event_enable`, the read end to void/fdwait.``
  []
  (def fds (buffer/new-filled 8))
  (unless (zero? (pipe- fds))
    (error "kafka: pipe(2) failed"))
  [(ffi/read :int fds 0) (ffi/read :int fds 4)])

(defn drain-pipe!
  ``Take whatever is in the pipe. Called only after fdwait said the
  descriptor is readable, so the read cannot block; anything left
  keeps the fd readable and the next pass drains again
  (level-triggered, ADR-0035).``
  [fd]
  (def buf (buffer/new-filled 256))
  (read- fd buf 256)
  nil)

(defn wake-byte!
  ``One byte into the write end — our own hand on the library's
  doorbell. The pump drains without counting, so a spurious byte costs
  one empty poll; a missing one costs a fiber parked forever, which is
  why `stop!` rings rather than hopes.``
  [fd]
  (write- fd "!" 1)
  nil)

(defn close-fd! [fd] (close- fd) nil)

# -- errors --------------------------------------------------------------

(defn err-str
  "rd_kafka_resp_err_t as its text."
  [code]
  (rd_kafka_err2str code))

(defn take-error!
  ``Consume an rd_kafka_error_t: nil in, nil out; otherwise its
  {:code :text}, with the object destroyed — the caller received
  ownership and this is where it ends.``
  [errp]
  (when errp
    (def out {:code (rd_kafka_error_code errp)
              :text (rd_kafka_error_string errp)})
    (rd_kafka_error_destroy errp)
    out))

# -- loading -------------------------------------------------------------

(var library-path
  "Path `load!` opened, nil before that."
  nil)

(var missing
  "Symbols an older library did not have — all of them optional, or
  `load!` would have failed."
  @[])

(defn available?
  "Have the bindings been opened?"
  []
  (not (nil? library-path)))

(defn candidates
  "The search order for a given configured path (nil = the defaults),
  environment override included."
  [&opt path]
  (cond
    path [path]
    (os/getenv path-env) [(os/getenv path-env)]
    default-candidates))

(defn- try-open [path]
  (def [ok lib] (protect (ffi/native path)))
  (when ok lib))

(defn- load-libc! []
  # the current process: pipe/read/close are always in it
  (def self (ffi/native))
  (defn bind [name ret & args]
    (def ptr (or (ffi/lookup self name)
                 (errorf "kafka: no %s in this process — cannot make the wake-up pipe" name)))
    (def sig (ffi/signature :default ret ;args))
    (fn [& call-args] (ffi/call ptr sig ;call-args)))
  (set pipe- (bind "pipe" :int :ptr))
  (set read- (bind "read" :long :int :ptr :ulong))
  (set write- (bind "write" :long :int :ptr :ulong))
  (set close- (bind "close" :int :int)))

(defn load!
  ``Open librdkafka and install the bindings. `path` (from
  [:kafka :library]) is tried alone; without it the platform defaults
  are, in order. Idempotent for the same path.``
  [&opt path]
  (when (and (available?) (or (nil? path) (= path library-path)))
    (break library-path))
  (def tried (candidates path))
  (var lib nil)
  (var found nil)
  (each c tried
    (unless lib
      (when-let [l (try-open c)]
        (set lib l)
        (set found c))))
  (unless lib
    (errorf (string "librdkafka not found — tried %s. Install it "
                    "(brew install librdkafka, apt install librdkafka1), or "
                    "point [:kafka :library] (or %s) at it")
            (string/join (map |(string/format "%q" $) tried) ", ")
            path-env))
  (def absent @[])
  (each b registry
    (def ptr (ffi/lookup lib (b :symbol)))
    (cond
      ptr
      (let [sig (ffi/signature :default (b :ret) ;(b :args))]
        ((b :install) (fn rk-call [& args] (ffi/call ptr sig ;args))))

      (b :optional)
      (do (array/push absent (b :symbol))
          ((b :install) nil))

      (errorf "%s has no symbol %s — is it really librdkafka?"
              found (b :symbol))))
  (load-libc!)
  (set missing absent)
  (set library-path found)
  found)

(defn version
  "What the loaded library calls itself — \"2.15.0\" or similar."
  []
  (when (available?) (rd_kafka_version_str)))
