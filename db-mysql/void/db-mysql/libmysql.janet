### void/db-mysql/libmysql — the libmysqlclient surface this driver uses,
### and nothing more.
###
### The shape is void/db-postgres/libpq's, for the same two reasons:
### the library path is configuration ([:db-mysql :library]) rather
### than a compile-time constant, and a plugin that merely gets loaded
### — `plugin/dry-run` in CI, `void routes` on a laptop with no MySQL
### — must not explode on import. Until `load!` runs, every binding is
### nil and `available?` says so.
###
### What is NOT the same is where `load!` runs. libpq is opened once, in
### the process's only VM, because libpq is asynchronous and the driver
### lives on the ev loop. Every call here blocks, so a connection lives on
### a worker thread of its own, and the bindings are installed *inside
### that thread* — a janet function crossing into a new VM carries plain
### data only, and an ffi native object is the definition of what cannot
### be marshalled. That is why this module is `var`s plus `load!` rather
### than `ffi/defbind` definitions: the worker calls `load!` on its own
### copy of the module and gets its own bindings. `void/crypto/kdf`
### explains the same constraint from the other end.
###
### Three libmysqlclient facts are load-bearing below:
###
###   * A `char *` return that can be NULL must be declared :ptr, not
###     :string. Janet's ffi builds a janet string straight off the
###     pointer, and off NULL that is a segfault rather than an error.
###     `mysql_error` returns "" and not NULL, so it can afford
###     :string; `mysql_fetch_row` hands back a `char **` that is NULL
###     at end-of-rows, so it cannot.
###   * `mysql_real_query` takes a length, which is what makes it —
###     and not `mysql_query` — the binding to have: a statement is
###     allowed to contain a NUL byte inside a quoted blob literal,
###     and the NUL-terminated call would truncate it there.
###   * Every thread that touches the library must `mysql_thread_init`
###     before its first call and `mysql_thread_end` before it exits,
###     or the per-thread arena leaks. `mysql_init` does the first
###     implicitly; nothing does the second, so the worker's exit path
###     calls it (see ./worker).
###
### MariaDB Connector/C ships the same `mysql_*` entry points behind
### `libmysqlclient.so` and is what CI and a Homebrew laptop actually
### load. The bindings below are the intersection both have had for a
### decade; anything newer than that is marked :optional and the
### driver falls back.

(def default-candidates
  ``Where the client library is looked for when nothing is
  configured, in order. A bare name goes through the dynamic loader's
  own search path (LD_LIBRARY_PATH, DYLD_*, /etc/ld.so.conf); the
  absolute ones are the usual keg locations, which are not on it —
  Homebrew keeps both mysql-client and mariadb-connector-c keg-only.

  MariaDB Connector/C is in the list on purpose and not as a
  fallback: it exports the same API under the same soname, it is what
  `brew install mariadb-connector-c` puts on a laptop, and a driver
  that insisted on Oracle's build would refuse to run on the machine
  most likely to be running it.``
  (case (os/which)
    :macos ["libmysqlclient.dylib"
            "/opt/homebrew/opt/mysql-client/lib/libmysqlclient.dylib"
            "/opt/homebrew/opt/mariadb-connector-c/lib/libmysqlclient.dylib"
            "/opt/homebrew/lib/libmariadb.dylib"
            "/usr/local/opt/mysql-client/lib/libmysqlclient.dylib"
            "/usr/local/opt/mariadb-connector-c/lib/libmysqlclient.dylib"]
    :windows ["libmysql.dll"]
    ["libmysqlclient.so.21" "libmysqlclient.so"
     "libmariadb.so.3" "libmariadb.so"]))

(def path-env
  "Environment variable that overrides the search — an escape hatch
  for a machine where the client library lives somewhere unusual and
  editing the config is not an option."
  "VOID_LIBMYSQL")

# -- bindings ------------------------------------------------------------

(def- registry
  "Every declared binding: {:symbol :ret :args :optional :install}."
  @[])

(defmacro- defmy
  ``Declare one libmysqlclient function: a module-level `var`, nil
  until `load!` installs the call. `& args` are ffi types; a trailing
  :optional marks a symbol an older library may not have.``
  [sym ret & args]
  (def optional (truthy? (index-of :optional args)))
  (def types (filter |(not= :optional $) args))
  ~(upscope
     (var ,sym nil)
     # `registry`, not `,registry`: unquoting an array splices an array
     # *literal* into the expansion, and a literal builds a fresh array
     # every time it is evaluated — each declaration would push into
     # its own copy and the real registry would stay empty
     (array/push registry
                 {:symbol ,(string sym)
                  :ret ,ret
                  # an array, not a tuple: a tuple of keywords in the
                  # expansion would be read as a call to :string
                  :args [,;types]
                  :optional ,optional
                  :install (fn [f] (set ,sym f))})))

# library and thread lifecycle
(defmy mysql_thread_init :int)
(defmy mysql_thread_end :void)
(defmy mysql_get_client_info :string)

# connection
(defmy mysql_init :ptr :ptr)
(defmy mysql_options :int :ptr :int :ptr)
(defmy mysql_real_connect :ptr :ptr :ptr :ptr :ptr :ptr :uint :ptr :ulong)
(defmy mysql_close :void :ptr)
(defmy mysql_ping :int :ptr)
(defmy mysql_select_db :int :ptr :string)
(defmy mysql_set_character_set :int :ptr :string)
(defmy mysql_character_set_name :string :ptr)
(defmy mysql_get_server_info :string :ptr)
(defmy mysql_get_server_version :ulong :ptr)
(defmy mysql_get_host_info :string :ptr)
(defmy mysql_thread_id :ulong :ptr)

# statements — the text protocol (explains why not mysql_stmt_*) both take
# an explicit length and both are declared :ptr rather than :string for
# the same reason: the bytes may contain a NUL — a blob literal inside the
# statement, a blob value being escaped — and a NUL-terminated argument
# would stop there
(defmy mysql_real_query :int :ptr :ptr :ulong)
(defmy mysql_real_escape_string :ulong :ptr :ptr :ptr :ulong)
(defmy mysql_store_result :ptr :ptr)
(defmy mysql_free_result :void :ptr)
(defmy mysql_field_count :uint :ptr)
(defmy mysql_affected_rows :u64 :ptr)
(defmy mysql_insert_id :u64 :ptr)
(defmy mysql_next_result :int :ptr)
(defmy mysql_more_results :int :ptr)

# results
(defmy mysql_num_fields :uint :ptr)
(defmy mysql_num_rows :u64 :ptr)
(defmy mysql_fetch_row :ptr :ptr)
(defmy mysql_fetch_lengths :ptr :ptr)
(defmy mysql_fetch_field_direct :ptr :ptr :uint)

# errors
(defmy mysql_errno :uint :ptr)
(defmy mysql_error :string :ptr)
(defmy mysql_sqlstate :string :ptr)

# -- constants -----------------------------------------------------------

(def MYSQL-OPT-CONNECT-TIMEOUT 0)
(def MYSQL-OPT-READ-TIMEOUT 11)
(def MYSQL-OPT-WRITE-TIMEOUT 12)
(def MYSQL-SET-CHARSET-NAME 7)
(def MYSQL-INIT-COMMAND 3)
(def MYSQL-OPT-RECONNECT 20)
(def MYSQL-OPT-SSL-CA 30)
(def MYSQL-OPT-SSL-CERT 31)
(def MYSQL-OPT-SSL-KEY 32)
(def MYSQL-OPT-SSL-MODE 44)

(def ssl-modes
  ``MYSQL_OPT_SSL_MODE's values. The names are the ones the server and
  the `mysql` client use, so a config that says :required means what
  the manual says it means.``
  {:disabled 1 :preferred 2 :required 3 :verify-ca 4 :verify-identity 5})

(def CLIENT-FOUND-ROWS 2)

(def client-flags
  ``The `client_flag` bits this driver may set. CLIENT_MULTI_STATEMENTS
  is deliberately absent: it turns one `mysql_real_query` into a
  statement *batch*, which is the difference between an injected
  string being a syntax error and being a second statement.``
  {:found-rows CLIENT-FOUND-ROWS})

(def error-codes
  ``The client and server errors this driver branches on, by name.
  Everything else travels as its number plus the server's own text.``
  {:server-gone 2006          # CR_SERVER_GONE_ERROR
   :server-lost 2013          # CR_SERVER_LOST
   :commands-out-of-sync 2014 # CR_COMMANDS_OUT_OF_SYNC
   :ssl-connection 2026       # CR_SSL_CONNECTION_ERROR
   :dup-entry 1062            # ER_DUP_ENTRY
   :no-such-table 1146        # ER_NO_SUCH_TABLE
   :lock-deadlock 1213        # ER_LOCK_DEADLOCK
   :lock-wait-timeout 1205})  # ER_LOCK_WAIT_TIMEOUT

(def client-error-range
  ``The CR_* codes: errors the client library raised about itself,
  rather than errors the server sent. The C API has reserved 2000-2999
  for them since forever, which is what makes the range a safer test
  than a list of names — MySQL's server codes are 1000-1999 and 4000+,
  and neither meets it.``
  [2000 2999])

(defn client-error?
  "Did the client library raise this, rather than the server?"
  [code]
  (and (>= code (client-error-range 0)) (<= code (client-error-range 1))))

(defn connection-lost?
  ``Is this error the connection dying, rather than the statement
  failing? The two the pool has to tell apart, and the reason the test
  is the whole client-error range rather than the two obvious codes:
  a session the server KILLs is reported as CR_SERVER_GONE_ERROR by
  one library and — over TLS, which is the default on MySQL 8 —
  as CR_SSL_CONNECTION_ERROR ("unexpected eof while reading") by
  another. Every CR_* code means the client library could not complete
  the exchange, and there is no such code after which the connection
  is worth keeping: a broken socket, a failed handshake and a
  desynchronised protocol all want the same repair.``
  [code]
  (client-error? code))

# -- field types ---------------------------------------------------------

(def field-types
  ``enum enum_field_types, by the number a MYSQL_FIELD carries. Only
  the ones ./types decides anything by are named; the rest arrive as
  their number and are read as text, which is what the text protocol
  hands over anyway.``
  {0 :decimal 1 :tiny 2 :short 3 :long 4 :float 5 :double 6 :null
   7 :timestamp 8 :longlong 9 :int24 10 :date 11 :time 12 :datetime
   13 :year 15 :varchar 16 :bit 245 :json 246 :newdecimal 247 :enum
   248 :set 249 :tiny-blob 250 :medium-blob 251 :long-blob 252 :blob
   253 :var-string 254 :string 255 :geometry})

(def BINARY-FLAG
  "MYSQL_FIELD.flags bit 7 — set when the column's collation is
  binary, which is how a BLOB is told from a TEXT (they share a type
  number)."
  128)

(def UNSIGNED-FLAG
  "MYSQL_FIELD.flags bit 5."
  32)

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

(defn cell-ptr
  ``The i-th `void *` of a C array of pointers, or nil where the cell
  holds NULL. This is how a MYSQL_ROW (a `char **`) is read: one cell
  per column, NULL for a SQL NULL — which is the only way the text
  protocol distinguishes NULL from the empty string.``
  [ptr i]
  (when ptr
    (def buf (ffi/pointer-buffer ptr (* cell-size (inc i)) (* cell-size (inc i)) 0))
    (ffi/read :ptr buf (* cell-size i))))

(defn cell-ulong
  ``The i-th `unsigned long` of a C array — how mysql_fetch_lengths's
  answer is read — as a plain number.

  The conversion is the point: janet's ffi hands an :ulong back as a
  core/u64, and a core/u64 is not something `ffi/pointer-buffer` or
  `string/slice` will take a length from. A column length always fits
  a double, so this is where it stops being a u64.``
  [ptr i]
  (when ptr
    (def buf (ffi/pointer-buffer ptr (* cell-size (inc i)) (* cell-size (inc i)) 0))
    (scan-number (string (ffi/read :ulong buf (* cell-size i))))))

(defn bytes-at
  ``Exactly `n` bytes from `ptr`, as a janet string. The text protocol
  hands
  values back as pointer plus length rather than as C strings, and
  the length is the half that matters: a BLOB column is allowed to
  contain a NUL and reading it as a C string would stop there.``
  [ptr n]
  (if (or (nil? ptr) (zero? n))
    ""
    (string (ffi/pointer-buffer ptr n n 0))))

# -- MYSQL_FIELD ---------------------------------------------------------
#
# The one struct this driver reads, and it reads four values out of it. Doing that by offset is a decision, not an oversight: the
# layout below is the head of MYSQL_FIELD, which has been stable across
# MySQL 5.x-8.x and MariaDB, whereas the *tail* is where the two have
# diverged (MariaDB has no `extension` pointer). Reading only the head,
# and only through `mysql_fetch_field_direct` (which hands back a
# pointer into libmysqlclient's own memory), keeps this to the part
# both libraries agree on.
#
#     0  char *name              8  char *org_name
#    16  char *table            24  char *org_table
#    32  char *db               40  char *catalog
#    48  char *def              56  unsigned long length
#    64  unsigned long max_length
#    72  unsigned int name_length      76  org_name_length
#    80  table_length                  84  org_table_length
#    88  db_length                     92  catalog_length
#    96  def_length            100  unsigned int flags
#   104  unsigned int decimals 108  unsigned int charsetnr
#   112  enum enum_field_types type
#   120  void *extension        <- past the head; the two libraries
#                                  disagree from here on, so nothing
#                                  below 120 is read
#
# `name` is at offset 0 in every version there has ever been, which is
# what makes it the field to check the whole layout with: ./worker runs
# `SELECT 1 AS <probe>` at connect and refuses the library if the name
# does not read back (see `probe-layout!`). A wrong guess then costs a
# boot error naming the library instead of a segfault on the first
# query.

(def- field-head 120)

(def field-offsets
  "Where the four values this driver reads live in a MYSQL_FIELD."
  {:name 0 :length 56 :flags 100 :type 112})

(defn field
  ``One column's metadata as {:name :length :type :flags}: the name,
  the declared width (which is the whole of how a BOOLEAN is told
  from a TINYINT — see ./types), the type as a `field-types` keyword
  (or its number, when it is one this driver does not name), and the
  raw flags for the BINARY/UNSIGNED bits.``
  [ptr]
  (when ptr
    (def buf (ffi/pointer-buffer ptr field-head field-head 0))
    (def code (ffi/read :uint buf (field-offsets :type)))
    {:name (cstr (ffi/read :ptr buf (field-offsets :name)))
     # a number, not the core/u64 the ffi hands back: ./types compares
     # it against 1 to find a boolean, and that comparison has to mean
     # what it looks like
     :length (scan-number (string (ffi/read :ulong buf (field-offsets :length))))
     :type (get field-types code code)
     :flags (ffi/read :uint buf (field-offsets :flags))}))

# -- loading -------------------------------------------------------------

(var library-path
  "Path `load!` opened, nil before that."
  nil)

(var missing
  "Symbols an older library did not have — all of them optional, or
  `load!` would have failed."
  @[])

(defn available?
  "Have the bindings been opened in THIS VM? A worker thread has its
  own answer, which is the point."
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
  ``Open libmysqlclient and install the bindings. `path` (from
  [:db-mysql :library]) is tried alone; without it the platform
  defaults are, in order. Idempotent for the same path.

  Returns the path opened; throws naming every candidate tried,
  because "cannot find the client library" is a message that has to
  say where it looked.``
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
    (errorf (string "libmysqlclient not found — tried %s. Install a MySQL "
                    "client library (brew install mysql-client or "
                    "mariadb-connector-c, apt install libmysqlclient21 or "
                    "libmariadb3), or point [:db-mysql :library] (or %s) at it")
            (string/join (map |(string/format "%q" $) tried) ", ")
            path-env))
  (def absent @[])
  (each b registry
    (def ptr (ffi/lookup lib (b :symbol)))
    (cond
      ptr
      (let [sig (ffi/signature :default (b :ret) ;(b :args))]
        ((b :install) (fn my-call [& args] (ffi/call ptr sig ;args))))

      (b :optional)
      (do (array/push absent (b :symbol))
          ((b :install) nil))

      (errorf "%s has no symbol %s — is it really a MySQL client library?"
              found (b :symbol))))
  (set missing absent)
  (set library-path found)
  found)

(defn client-version
  "What the loaded library calls itself — \"8.0.36\" for Oracle's,
  \"3.3.8\" for MariaDB Connector/C. A string, because the two number
  it differently and neither is the server's version."
  []
  (when (available?) (mysql_get_client_info)))

(defn server-version
  ``A connection's server version as [major minor patch].
  mysql_get_server_version reports 80036 for 8.0.36 and 110402 for
  MariaDB 11.4.2.``
  [conn]
  # the ffi hands :ulong back as a core/u64; the version is three
  # small numbers and reads like one
  (def n (scan-number (string (mysql_get_server_version conn))))
  [(div n 10000) (mod (div n 100) 100) (mod n 100)])
