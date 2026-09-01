### void/db-postgres/config — from the [:db-postgres] config slice to
### the connection string libpq opens (SPEC.md §5.10).
###
### libpq takes either a keyword string (`host=db user=void`) or a URI
### (`postgres://void@db/app`), and it fills in whatever neither one
### mentions from the environment — PGHOST, PGUSER, PGPASSWORD,
### ~/.pgpass, ~/.postgresql/root.crt. That is a feature worth keeping:
### the defaults here add an application name and nothing else, so a
### zero-config boot connects exactly where psql would, and a
### twelve-factor deployment can pass DATABASE_URL and stop.
###
### Both spellings meet here as keywords, because a URI cannot be
### *extended*: libpq parses one form or the other, so
### {:url "postgres://db/app" :application-name "worker"} has to become
### one string, and the only way to get there is to take the URI apart.
### That also makes precedence something to state rather than discover
### — an explicit key beats the same key inside the URL:
###
###     {:url "postgres://void:s3cret@db.internal:6432/app?sslmode=require"
###      :application-name "importer"     # wins over the URL's, if any
###      :statement-timeout 30000}        # -c statement_timeout=30000
###
### Server-side settings (:statement-timeout, :search-path, :settings)
### travel as libpq's `options` keyword — `-c name=value`, applied by
### the backend as it starts. They cost no round trip, unlike a SET
### after connecting, and they apply to the very first statement.
### :settings takes any of them, which is also the answer to the one
### thing this driver cannot intercept: libpq prints server NOTICEs to
### stderr itself (see ./libpq), and `{:settings {:client-min-messages
### "warning"}}` is how to stop producing them.
###
### Nothing here talks to libpq: this module is pure string building,
### which is why its whole surface is testable without a server.

# -- the config slice ----------------------------------------------------

(def Config
  ``Schema of the [:db-postgres] config slice.``
  {:url [:optional :string]
   :host [:optional :string]
   :port [:optional [:int {:min 1 :max 65535}]]
   :database [:optional :string]
   :user [:optional :string]
   :password [:optional :string]
   :application-name [:optional :string]

   # TLS is libpq's own — the driver adds nothing to it (ADR-0011)
   :sslmode [:optional [:enum :disable :allow :prefer :require
                        :verify-ca :verify-full]]
   :sslrootcert [:optional :string]
   :sslcert [:optional :string]
   :sslkey [:optional :string]

   # server-side settings, as -c name=value
   :statement-timeout [:optional [:int {:min 0}]]
   :lock-timeout [:optional [:int {:min 0}]]
   :idle-in-transaction-timeout [:optional [:int {:min 0}]]
   :search-path [:optional :string]
   :timezone [:optional :string]
   :settings [:optional :dictionary]

   # escape hatch: any other libpq keyword, verbatim
   :params [:optional :dictionary]

   # driver behaviour, not connection parameters
   :libpq [:optional :string]
   :connect-timeout [:optional [:number {:min 0}]]
   :prepared [:optional :boolean]
   :reconnect [:optional :boolean]
   :json [:optional :boolean]
   :arrays [:optional :boolean]
   :tx-mode [:optional [:enum :read-uncommitted :read-committed
                        :repeatable-read :serializable]]})

(def defaults
  ``Defaults of the [:db-postgres] slice. Deliberately almost empty:
  every connection parameter left out is one libpq resolves from the
  environment the way psql would, and a driver that hardcoded
  host=localhost would break exactly the deployments that pass PGHOST.

  What is defaulted is what libpq has no opinion about — a name to
  show up as in pg_stat_activity, a handshake deadline that is ours
  rather than the socket's, and the prepared-statement path being on.``
  {:application-name "void"
   :connect-timeout 10
   :prepared true
   :reconnect true})

# -- URLs ----------------------------------------------------------------

(def url-schemes
  "The two scheme spellings libpq accepts for a connection URI."
  ["postgresql://" "postgres://"])

(defn url?
  "Does this string look like a Postgres connection URI?"
  [s]
  (def t (string s))
  (truthy? (some |(string/has-prefix? $ t) url-schemes)))

(def- hex-digits
  (let [t @{}]
    (eachp [i c] "0123456789abcdef" (put t c i))
    (eachp [i c] "0123456789ABCDEF" (put t c i))
    (table/to-struct t)))

(defn percent-decode
  ``Undo the %XX escaping of a URI component. A stray % that does not
  introduce two hex digits is a typo in a connection string, and
  saying so beats connecting somewhere unintended.``
  [s]
  (def out (buffer/new (length s)))
  (var i 0)
  (while (< i (length s))
    (def c (s i))
    (if (= c 37)                                    # %
      (let [hi (get hex-digits (get s (+ i 1)))
            lo (get hex-digits (get s (+ i 2)))]
        (when (or (nil? hi) (nil? lo))
          (errorf "postgres: %q is not a valid percent-escape in a connection URL"
                  (string/slice s i (min (length s) (+ i 3)))))
        (buffer/push-byte out (+ (* 16 hi) lo))
        (+= i 3))
      (do (buffer/push-byte out c) (++ i))))
  (string out))

(defn- split-once [s sep]
  (if-let [i (string/find sep s)]
    [(string/slice s 0 i) (string/slice s (+ i (length sep)))]
    [s nil]))

(defn- split-last [s sep]
  (if-let [i (last (string/find-all sep s))]
    [(string/slice s 0 i) (string/slice s (+ i (length sep)))]
    [nil s]))

(defn- host-port
  ``One entry of a URI's host list as [host port]. An IPv6 literal is
  bracketed, which is the whole reason this is not a split on ":".``
  [entry]
  (if (string/has-prefix? "[" entry)
    (let [close (string/find "]" entry)]
      (unless close
        (errorf "postgres: %q has an unclosed IPv6 literal" entry))
      (def host (string/slice entry 1 close))
      (def rest (string/slice entry (inc close)))
      [host (when (string/has-prefix? ":" rest) (string/slice rest 1))])
    (let [[h p] (split-once entry ":")] [h p])))

(defn parse-url
  ``A Postgres connection URI as the libpq keywords it stands for:

      (parse-url "postgres://void:s3cret@db:6432/app?sslmode=require")
      # -> {:user "void" :password "s3cret" :host "db" :port "6432"
      #     :database "app" :params {"sslmode" "require"}}

  Multi-host URIs keep libpq's own spelling — host "a,b", port
  "5432,5433" — since that is exactly what the keyword form takes.
  Every component is percent-decoded, so a password with an @ or a /
  in it survives the trip.``
  [url]
  (def scheme (find |(string/has-prefix? $ url) url-schemes))
  (unless scheme
    (errorf "postgres: %q is not a connection URL (expected postgres:// or postgresql://)"
            url))
  (def body (string/slice url (length scheme)))
  (def [before-query query] (split-once body "?"))
  # the authority ends at the first / — a path separator cannot appear
  # in a host, and one inside a password has to arrive as %2F
  (def [authority path] (split-once before-query "/"))
  # ... but an @ can appear in a percent-free password, so the userinfo
  # boundary is the LAST one
  (def [userinfo hostspec] (split-last authority "@"))
  (def [user password] (if userinfo (split-once userinfo ":") [nil nil]))
  (def hosts (if (or (nil? hostspec) (empty? hostspec))
               []
               (map host-port (string/split "," hostspec))))
  (def out @{})
  (defn put-decoded [k v]
    (when (and v (not (empty? v))) (put out k (percent-decode v))))
  (put-decoded :user user)
  (put-decoded :password password)
  (unless (empty? hosts)
    (put-decoded :host (string/join (map |(percent-decode (or (first $) "")) hosts) ","))
    # a port list is only meaningful when at least one entry has one
    (when (some |(get $ 1) hosts)
      (put out :port (string/join (map |(or (get $ 1) "") hosts) ","))))
  (put-decoded :database path)
  (def params @{})
  (when (and query (not (empty? query)))
    (each pair (string/split "&" query)
      (unless (empty? pair)
        (def [k v] (split-once pair "="))
        (put params (percent-decode k) (percent-decode (or v ""))))))
  (unless (empty? params) (put out :params params))
  out)

# -- keyword strings -----------------------------------------------------

(defn quote-value
  ``One conninfo value, always single-quoted. libpq only *needs* the
  quotes around a value with a space or an equals sign in it, and
  quoting unconditionally means never having to decide which values
  those are — a password is exactly the value that will one day
  contain the character nobody thought of.``
  [v]
  (def out (buffer/new (+ 2 (length (string v)))))
  (buffer/push-byte out 39)                          # '
  (each c (string v)
    (when (or (= c 39) (= c 92)) (buffer/push-byte out 92))
    (buffer/push-byte out c))
  (buffer/push-byte out 39)
  (string out))

(def keyword-names
  ``The libpq keyword each named config key maps to. Keys not in here
  are either driver behaviour (:prepared, :libpq) or become backend
  settings (see `settings`).``
  {:host "host"
   :port "port"
   :database "dbname"
   :user "user"
   :password "password"
   :application-name "application_name"
   :sslmode "sslmode"
   :sslrootcert "sslrootcert"
   :sslcert "sslcert"
   :sslkey "sslkey"})

(def- setting-names
  "Named config keys that travel as a backend `-c name=value`."
  {:statement-timeout "statement_timeout"
   :lock-timeout "lock_timeout"
   :idle-in-transaction-timeout "idle_in_transaction_session_timeout"
   :search-path "search_path"
   :timezone "TimeZone"})

(def- setting-value-peg
  # a backend option is passed inside libpq's `options` value, where a
  # space separates options and would have to be escaped through two
  # layers; refusing one is clearer than escaping it
  (peg/compile ~(* (some (+ (range "az" "AZ" "09") (set "_-.,:+$\"'"))) -1)))

(defn settings
  ``The server-side settings of a config slice as [name value] pairs,
  in a stable order: the named ones first, then whatever [:settings]
  adds. These become libpq's `options` keyword.``
  [cfg]
  (def out @[])
  (each k [:statement-timeout :lock-timeout :idle-in-transaction-timeout
           :search-path :timezone]
    (when-let [v (get cfg k)]
      (array/push out [(setting-names k) v])))
  (eachp [k v] (get cfg :settings {})
    (array/push out [(string/replace-all "-" "_" (string k)) v]))
  out)

(defn options-value
  ``The `options` keyword: `-c name=value` per setting, or nil when
  there are none.

  A value with a space in it is refused rather than escaped. It would
  have to survive both this string and the conninfo quoting around it,
  and a search_path that silently loses half its schemas is a bug
  found in production; the settings that need one belong in a SET
  statement of your own.``
  [cfg]
  (def pairs (settings cfg))
  (when (empty? pairs) (break nil))
  (string/join
    (seq [[name value] :in pairs]
      (def v (string value))
      (unless (peg/match setting-value-peg v)
        (errorf (string "postgres: %s=%q cannot travel as a startup option "
                        "(no spaces or shell characters) — run it as a SET "
                        "statement instead")
                name value))
      (string "-c " name "=" v))
    " "))

(defn keywords
  ``The full libpq keyword list of a config slice, as [keyword value]
  pairs in a stable order: what the URL says, then the explicit keys
  (which override it), then [:params], then the assembled `options`.``
  [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (def from-url (if-let [u (get cfg :url)] (parse-url u) {}))
  (def out @[])
  (def seen @{})
  (defn add [name value]
    (unless (or (nil? value) (= "" (string value)))
      (unless (get seen name)
        (put seen name true)
        (array/push out [name (string value)]))))
  # explicit keys first — `add` keeps the first value for a keyword, so
  # "first" is the same statement as "wins"
  (each [k name] (sorted-by |(get $ 1) (pairs keyword-names))
    (add name (get cfg k)))
  (eachp [k v] (get cfg :params {})
    (add (string/replace-all "-" "_" (string k)) v))
  (add "options" (options-value cfg))
  (each [k name] (sorted-by |(get $ 1) (pairs keyword-names))
    (add name (get from-url k)))
  (eachp [k v] (get from-url :params {})
    (add (string k) v))
  out)

(defn conninfo
  ``The connection string for a [:db-postgres] slice. Everything it
  does not mention is libpq's to resolve from the environment.``
  [cfg]
  (string/join
    (seq [[name value] :in (keywords cfg)]
      (string name "=" (quote-value value)))
    " "))

(def- secret-keywords
  "Keywords whose value never belongs in a log line."
  {"password" true "sslpassword" true})

(defn safe-conninfo
  ``The same string with every secret replaced — what gets logged. The
  keywords stay: \"which parameters did it connect with\" is the
  question a log line is there to answer.``
  [cfg]
  (string/join
    (seq [[name value] :in (keywords cfg)]
      (string name "=" (quote-value (if (get secret-keywords name) "***" value))))
    " "))

(defn describe
  ``The connection as a handful of values for a log line or a health
  report: {:host :port :database :user :sslmode :application-name},
  with no secret among them. A key libpq will resolve from the
  environment is absent rather than guessed at.``
  [cfg]
  (def kw (from-pairs (keywords cfg)))
  (def out @{})
  (each [k name] [[:host "host"] [:port "port"] [:database "dbname"]
                  [:user "user"] [:sslmode "sslmode"]
                  [:application-name "application_name"]]
    (when-let [v (get kw name)] (put out k v)))
  (table/to-struct out))

# -- driver behaviour ----------------------------------------------------

(defn decode-opts
  ``The ./types decoding options a slice asks for: :json false leaves
  json/jsonb as text, :arrays false leaves array columns as their
  literal.``
  [cfg]
  (def out @{})
  (each k [:json :arrays]
    (unless (nil? (get cfg k)) (put out k (get cfg k))))
  (table/to-struct out))
