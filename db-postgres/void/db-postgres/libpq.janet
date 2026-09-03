### void/db-postgres/libpq — the libpq surface this driver uses, and
### nothing more (Appendix A).
###
### Everything here is `ffi/`: libpq is a C library with a complete
### non-blocking API, so there is no reason to reimplement the
### Postgres wire protocol and no reason to write C. The one thing
### Janet genuinely cannot do — wait on a descriptor libpq owns — is
### void/fdwait, and that is the whole native footprint.
###
### The bindings are `var`s installed by `load!` rather than
### `ffi/defbind` definitions, for two reasons: the library path is
### configuration ([:db-postgres :libpq]), not a compile-time
### constant, and a plugin that merely gets loaded — `plugin/dry-run`
### in CI, `void routes` on a laptop without Postgres — must not
### explode on import. Until `load!` runs, every binding is nil and
### `available?` says so.
###
### Two libpq facts are load-bearing in the bindings below:
###
###   * A `char *` return that can be NULL must be declared :ptr, not
###     :string. Janet's ffi builds a janet string straight off the
###     pointer, and off NULL that is a segfault, not an error — so
###     `PQresultErrorField` (NULL for an absent field) goes through
###     `cstr`, while `PQgetvalue` (documented non-NULL, and the hot
###     path) can afford :string.
###   * Symbols come and go between versions. `PQcancelCreate` and
###     friends are libpq 17+; the bindings marked :optional stay nil
###     on an older library and the driver falls back (see ./conn).
###
### One thing these bindings deliberately do NOT do: replace libpq's
### notice processor. A server NOTICE or WARNING ("table does not
### exist, skipping") is printed to stderr by libpq itself, which is
### not where a structured logger wants it — but redirecting it means
### handing libpq a C function pointer, and janet's `ffi/` cannot make
### one. The lever that does exist is the server's own
### `client_min_messages`, through [:db-postgres :settings]; see
### ./config.

(def default-candidates
  ``Where libpq is looked for when nothing is configured, in order.
  A bare name goes through the dynamic loader's own search path
  (LD_LIBRARY_PATH, DYLD_*, /etc/ld.so.conf); the absolute ones are
  the usual keg/installer locations, which are not on it — Homebrew
  keeps libpq keg-only precisely because it collides with the
  system's.``
  (case (os/which)
    :macos ["libpq.dylib"
            "/opt/homebrew/opt/libpq/lib/libpq.dylib"
            "/usr/local/opt/libpq/lib/libpq.dylib"
            "/Library/PostgreSQL/17/lib/libpq.dylib"
            "/Library/PostgreSQL/16/lib/libpq.dylib"]
    :windows ["libpq.dll"]
    ["libpq.so.5" "libpq.so"]))

(def path-env
  "Environment variable that overrides the search — an escape hatch
  for a machine where libpq lives somewhere unusual and editing the
  config is not an option."
  "VOID_LIBPQ")

# -- bindings ------------------------------------------------------------

(def- registry
  "Every declared binding: {:symbol :ret :args :optional :install}."
  @[])

(defmacro- defpq
  ``Declare one libpq function: a module-level `var`, nil until
  `load!` installs the call. `& args` are ffi types; a trailing
  :optional marks a symbol that may be absent from an older libpq.``
  [sym ret & args]
  (def optional (truthy? (index-of :optional args)))
  (def types (filter |(not= :optional $) args))
  ~(upscope
     (var ,sym nil)
     # `registry`, not `,registry`: unquoting an array splices an array
     # *literal* into the expansion, and a literal builds a fresh array
     # every time it is evaluated — each declaration would push into its
     # own copy and the real registry would stay empty
     (array/push registry
                 {:symbol ,(string sym)
                  :ret ,ret
                  # an array, not a tuple: a tuple of keywords in the
                  # expansion would be read as a call to :string
                  :args [,;types]
                  :optional ,optional
                  :install (fn [f] (set ,sym f))})))

# connection
(defpq PQconnectStart :ptr :string)
(defpq PQconnectPoll :int :ptr)
(defpq PQstatus :int :ptr)
(defpq PQfinish :void :ptr)
(defpq PQsocket :int :ptr)
(defpq PQsetnonblocking :int :ptr :int)
(defpq PQerrorMessage :string :ptr)
(defpq PQtransactionStatus :int :ptr)
(defpq PQserverVersion :int :ptr)
(defpq PQprotocolVersion :int :ptr)
(defpq PQbackendPID :int :ptr)
(defpq PQparameterStatus :ptr :ptr :string)
(defpq PQlibVersion :int)
(defpq PQfreemem :void :ptr)

# sending and receiving
(defpq PQsendQuery :int :ptr :string)
(defpq PQsendQueryParams :int :ptr :string :int :ptr :ptr :ptr :ptr :int)
(defpq PQsendPrepare :int :ptr :string :string :int :ptr)
(defpq PQsendQueryPrepared :int :ptr :string :int :ptr :ptr :ptr :int)
(defpq PQflush :int :ptr)
(defpq PQconsumeInput :int :ptr)
(defpq PQisBusy :int :ptr)
(defpq PQgetResult :ptr :ptr)
(defpq PQsetSingleRowMode :int :ptr)

# results
(defpq PQresultStatus :int :ptr)
(defpq PQresStatus :string :int)
(defpq PQntuples :int :ptr)
(defpq PQnfields :int :ptr)
(defpq PQfname :string :ptr :int)
(defpq PQftype :uint :ptr :int)
(defpq PQgetvalue :string :ptr :int :int)
(defpq PQgetisnull :int :ptr :int :int)
(defpq PQcmdTuples :string :ptr)
(defpq PQcmdStatus :string :ptr)
(defpq PQoidValue :uint :ptr)
(defpq PQclear :void :ptr)
(defpq PQresultErrorMessage :string :ptr)
(defpq PQresultErrorField :ptr :ptr :int)

# asynchronous notification
(defpq PQnotifies :ptr :ptr)

# pipeline mode (libpq 14+)
(defpq PQenterPipelineMode :int :ptr :optional)
(defpq PQexitPipelineMode :int :ptr :optional)
(defpq PQpipelineSync :int :ptr :optional)
(defpq PQpipelineStatus :int :ptr :optional)
(defpq PQsendFlushRequest :int :ptr :optional)

# cancellation — the non-blocking API is libpq 17+, the blocking one
# has been there forever
(defpq PQcancelCreate :ptr :ptr :optional)
(defpq PQcancelStart :int :ptr :optional)
(defpq PQcancelPoll :int :ptr :optional)
(defpq PQcancelSocket :int :ptr :optional)
(defpq PQcancelStatus :int :ptr :optional)
(defpq PQcancelErrorMessage :ptr :ptr :optional)
(defpq PQcancelFinish :void :ptr :optional)
(defpq PQgetCancel :ptr :ptr :optional)
(defpq PQcancel :int :ptr :ptr :int :optional)
(defpq PQfreeCancel :void :ptr :optional)

# -- constants -----------------------------------------------------------

(def CONNECTION-OK 0)
(def CONNECTION-BAD 1)

(def POLLING-FAILED 0)
(def POLLING-READING 1)
(def POLLING-WRITING 2)
(def POLLING-OK 3)

(def PGRES-EMPTY-QUERY 0)
(def PGRES-COMMAND-OK 1)
(def PGRES-TUPLES-OK 2)
(def PGRES-COPY-OUT 3)
(def PGRES-COPY-IN 4)
(def PGRES-BAD-RESPONSE 5)
(def PGRES-NONFATAL-ERROR 6)
(def PGRES-FATAL-ERROR 7)
(def PGRES-COPY-BOTH 8)
(def PGRES-SINGLE-TUPLE 9)
(def PGRES-PIPELINE-SYNC 10)
(def PGRES-PIPELINE-ABORTED 11)

(def PQTRANS-IDLE 0)
(def PQTRANS-ACTIVE 1)
(def PQTRANS-INTRANS 2)
(def PQTRANS-INERROR 3)
(def PQTRANS-UNKNOWN 4)

(def PIPELINE-OFF 0)
(def PIPELINE-ON 1)
(def PIPELINE-ABORTED 2)

(def diag-fields
  ``PG_DIAG_* error fields, by the character code libpq indexes them
  with. These are what turns "duplicate key value violates unique
  constraint" into something a caller can branch on.``
  {:severity 83      # S
   :sqlstate 67      # C
   :message 77       # M
   :detail 68        # D
   :hint 72          # H
   :position 80      # P
   :internal-position 112
   :internal-query 113
   :where 87         # W
   :schema 115       # s
   :table 116        # t
   :column 99        # c
   :datatype 100     # d
   :constraint 110}) # n

# -- pointer helpers -----------------------------------------------------

(def- cell-size 8)

(defn cstr
  ``A `char *` that may be NULL, as a janet string or nil. Bindings
  that can return NULL are declared :ptr for exactly this: janet's
  ffi reads a :string return straight off the pointer, and off NULL
  that is a segfault rather than an error.``
  [ptr]
  (when ptr
    (def cell (buffer/new-filled cell-size))
    (ffi/write :ptr ptr cell 0)
    (ffi/read :string cell 0)))

(defn cstr-array
  ``A `char *[]` for the paramValues of PQsendQueryParams: one cell
  per value, NULL where the value is nil (which is how a SQL NULL is
  passed). Returns [buffer keepalive] — the strings must stay
  reachable until the call returns, since the cells hold pointers
  into them and janet has no idea.``
  [strings]
  (def n (length strings))
  (when (zero? n) (break [nil []]))
  (def cells (buffer/new-filled (* cell-size n)))
  (def keepalive @[])
  (eachp [i s] strings
    (unless (nil? s)
      (array/push keepalive s)
      (ffi/write :string s cells (* cell-size i))))
  [cells keepalive])

(def- notify-size 32)   # char* + int + padding + char* + char*

(defn notification
  ``Read a PGnotify the way libpq lays it out — {:channel :pid
  :payload} — without freeing it; the caller does that with
  PQfreemem, since the strings are copied out of libpq's memory
  here.``
  [ptr]
  (when ptr
    (def buf (ffi/pointer-buffer ptr notify-size notify-size 0))
    {:channel (ffi/read :string buf 0)
     :pid (ffi/read :int buf 8)
     :payload (ffi/read :string buf 16)}))

# -- loading -------------------------------------------------------------

(var library-path
  "Path `load!` opened, nil before that."
  nil)

(var missing
  "Symbols an older libpq did not have — all of them optional, or
  `load!` would have failed."
  @[])

(defn available?
  "Has libpq been loaded into these bindings?"
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

(defn load!
  ``Open libpq and install the bindings. `path` (from
  [:db-postgres :libpq]) is tried alone; without it the platform
  defaults are, in order. Idempotent for the same path — reopening a
  different one re-installs the bindings, which is what a REPL
  reload wants.

  Returns the path opened; throws naming every candidate tried,
  because "cannot find libpq" is a message that has to say where it
  looked.``
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
    (errorf (string "libpq not found — tried %s. Install the Postgres client "
                    "library (brew install libpq, apt install libpq5), or "
                    "point [:db-postgres :libpq] (or %s) at it")
            (string/join (map |(string/format "%q" $) tried) ", ")
            path-env))
  (def absent @[])
  (each b registry
    (def ptr (ffi/lookup lib (b :symbol)))
    (cond
      ptr
      (let [sig (ffi/signature :default (b :ret) ;(b :args))]
        ((b :install) (fn pq-call [& args] (ffi/call ptr sig ;args))))

      (b :optional)
      (do (array/push absent (b :symbol))
          ((b :install) nil))

      (errorf "%s has no symbol %s — is it really libpq?" found (b :symbol))))
  (set missing absent)
  (set library-path found)
  found)

(defn version
  "The loaded libpq's version as [major minor], or nil before `load!`.
  libpq reports 160014 for 16.14 and 180006 for 18.6."
  []
  (when (available?)
    (def n (PQlibVersion))
    [(div n 10000) (mod (div n 100) 100)]))

(defn supports?
  ``Whether an optional feature's symbols made it in:
    :pipeline  PQenterPipelineMode & co (libpq 14+)
    :cancel    the non-blocking PQcancelStart poll loop (libpq 17+)
  Anything else is a mistake, not a false.``
  [feature]
  (case feature
    :pipeline (and PQenterPipelineMode PQpipelineSync true)
    :cancel (and PQcancelCreate PQcancelStart PQcancelPoll true)
    (errorf "libpq/supports?: unknown feature %q (:pipeline :cancel)" feature)))
