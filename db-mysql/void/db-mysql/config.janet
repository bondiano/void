### void/db-mysql/config — from the [:db-mysql] config slice to the
### plain-data spec a worker thread connects with.
###
### void/db-postgres/config has to build a *string*, because libpq
### parses one. libmysqlclient does not: `mysql_real_connect` takes
### seven arguments and `mysql_options` takes the rest, so the spec
### here stays a dictionary all the way to the C call and nothing is
### ever quoted, escaped or re-parsed.
###
### That leaves this module with two jobs. One is the URL, which
### exists because a twelve-factor deployment passes DATABASE_URL and
### stops; precedence is stated rather than discovered — an explicit
### key beats the same key inside the URL:
###
###     {:url "mysql://void:s3cret@db.internal:3307/app?ssl-mode=required"
###      :user "importer"}          # wins over the URL's "void"
###
### The other is the environment. Unlike libpq, libmysqlclient reads
### almost nothing from it — there is no PGHOST equivalent that
### deployments actually use — so the defaults below are a real
### localhost rather than "whatever the client resolves". What IS
### read, and only when nothing else says otherwise, is MYSQL_HOST,
### because the `mysql` client reads it and a machine that has it set
### means it.
###
### Nothing here loads the library or opens anything: this module is
### pure data, which is why its whole surface is testable without a
### server.

# -- the config slice ----------------------------------------------------

(def Config
  "Schema of the [:db-mysql] config slice."
  {:url [:optional :string]
   :host [:optional :string]
   :port [:optional [:int {:min 1 :max 65535}]]
   :socket [:optional :string]
   :database [:optional :string]
   :user [:optional :string]
   :password [:optional :string]

   # TLS is the client library's own — the driver adds nothing to it
   #
   :ssl-mode [:optional [:enum :disabled :preferred :required
                         :verify-ca :verify-identity]]
   :ssl-ca [:optional :string]
   :ssl-cert [:optional :string]
   :ssl-key [:optional :string]

   # session settings
   :charset [:optional :string]
   :init-command [:optional :string]
   :time-zone [:optional :string]
   :sql-mode [:optional :string]

   # driver behaviour, not connection parameters
   :library [:optional :string]
   :connect-timeout [:optional [:number {:min 0}]]
   :read-timeout [:optional [:number {:min 0}]]
   :write-timeout [:optional [:number {:min 0}]]
   :reconnect [:optional :boolean]
   :found-rows [:optional :boolean]
   :json [:optional :boolean]
   :booleans [:optional :boolean]
   :tx-mode [:optional [:enum :read-uncommitted :read-committed
                        :repeatable-read :serializable]]})

(def fallbacks
  ``What a key falls back to when neither the config nor the URL says.

  utf8mb4 is not negotiable enough to be worth leaving out: MySQL's
  "utf8" is a three-byte subset that cannot store an emoji or half of
  CJK, it is still the server default on installations in the field,
  and the charset is also what the parameter escaping is correct with
  respect to (./worker). A deployment that genuinely runs latin1 sets
  :charset and knows why.

  :found-rows makes an UPDATE report the rows it matched rather than
  the rows it changed — see ./worker for why that is the portable
  reading and not a preference.``
  {:host "127.0.0.1"
   :port 3306
   :charset "utf8mb4"
   :connect-timeout 10
   :reconnect true
   :found-rows true})

(def defaults
  ``Defaults of the [:db-mysql] slice — and deliberately empty, which
  is worth the paragraph it costs.

  These are what the *kernel* merges into the slice before this plugin
  sees it, and a merged default is indistinguishable from a choice. A
  slice is allowed to say everything twice — once in :url and once in
  a key — and this module has to resolve that ("an explicit key beats
  the URL"), which it can only do while it can still tell what was
  written down. Declaring :port 3306 as a config default would arrive
  looking exactly like a deployment that meant 3306, and quietly beat
  the :3307 in its own connection URL.

  So the real values live in `fallbacks`, and `spec` applies them
  last: config, then URL, then these. The effective defaults are the
  same either way; which of them is a decision is not.``
  {})

(def host-env
  "The one environment variable the `mysql` client reads that a
  deployment actually sets."
  "MYSQL_HOST")

# -- URLs ----------------------------------------------------------------

(def url-schemes
  "The scheme spellings accepted for a connection URL. MariaDB's own
  tooling writes mariadb://, and it means the same thing here."
  ["mysql://" "mariadb://"])

(defn url?
  "Does this string look like a MySQL connection URL?"
  [s]
  (def t (string s))
  (truthy? (some |(string/has-prefix? $ t) url-schemes)))

(def- hex-digits
  (let [t @{}]
    (eachp [i c] "0123456789abcdef" (put t c i))
    (eachp [i c] "0123456789ABCDEF" (put t c i))
    (table/to-struct t)))

(defn percent-decode
  ``Undo the %XX escaping of a URL component. A stray % that does not
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
          (errorf "mysql: %q is not a valid percent-escape in a connection URL"
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

(def- url-keys
  ``Query parameters a URL may carry, and the config key each is. The
  list is closed on purpose: an unknown parameter in a connection
  string is a typo that would otherwise be ignored until someone
  wondered why TLS was off.``
  {"ssl-mode" :ssl-mode "sslmode" :ssl-mode
   "ssl-ca" :ssl-ca "ssl-cert" :ssl-cert "ssl-key" :ssl-key
   "charset" :charset "time-zone" :time-zone "sql-mode" :sql-mode
   "socket" :socket "connect-timeout" :connect-timeout
   "read-timeout" :read-timeout "write-timeout" :write-timeout
   "found-rows" :found-rows "reconnect" :reconnect})

(def- boolean-keys {:found-rows true :reconnect true})
(def- number-keys {:connect-timeout true :read-timeout true :write-timeout true})
(def- keyword-keys {:ssl-mode true})

(defn- url-value [key raw]
  (cond
    (boolean-keys key)
    (case raw
      "true" true "1" true "yes" true "on" true
      "false" false "0" false "no" false "off" false
      (errorf "mysql: %q is not a true/false value for %q in a connection URL"
              raw key))
    (number-keys key)
    (or (scan-number raw)
        (errorf "mysql: %q is not a number for %q in a connection URL" raw key))
    (keyword-keys key) (keyword raw)
    raw))

(defn parse-url
  ``A MySQL connection URL as the config keys it stands for:

      (parse-url "mysql://void:s3cret@db:3307/app?ssl-mode=required")
      # -> {:user "void" :password "s3cret" :host "db" :port 3307
      #     :database "app" :ssl-mode :required}

  A unix socket travels as the query parameter the `mysql` client
  spells it with — mysql://user@/app?socket=/tmp/mysql.sock — since a
  path cannot go in the authority. Every component is
  percent-decoded, so a password with an @ or a / in it survives the
  trip.``
  [url]
  (def scheme (find |(string/has-prefix? $ url) url-schemes))
  (unless scheme
    (errorf "mysql: %q is not a connection URL (expected mysql:// or mariadb://)"
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
  (def out @{})
  (defn put-decoded [k v]
    (when (and v (not (empty? v))) (put out k (percent-decode v))))
  (put-decoded :user user)
  (put-decoded :password password)
  (put-decoded :database path)
  (when (and hostspec (not (empty? hostspec)))
    # an IPv6 literal is bracketed, which is the whole reason this is
    # not a split on ":"
    (if (string/has-prefix? "[" hostspec)
      (let [close (or (string/find "]" hostspec)
                      (errorf "mysql: %q has an unclosed IPv6 literal" hostspec))
            rest (string/slice hostspec (inc close))]
        (put-decoded :host (string/slice hostspec 1 close))
        (when (string/has-prefix? ":" rest)
          (put out :port (scan-number (string/slice rest 1)))))
      (let [[h p] (split-once hostspec ":")]
        (put-decoded :host h)
        (when (and p (not (empty? p)))
          (put out :port
               (or (scan-number p)
                   (errorf "mysql: %q is not a port in a connection URL" p)))))))
  (when (and query (not (empty? query)))
    (each pair (string/split "&" query)
      (unless (empty? pair)
        (def [k v] (split-once pair "="))
        (def name (percent-decode k))
        (def key (or (get url-keys name)
                     (errorf (string "mysql: %q is not a connection URL "
                                     "parameter this driver knows (known: %s)")
                             name
                             (string/join (sorted (keys url-keys)) " "))))
        (put out key (url-value key (percent-decode (or v "")))))))
  out)

# -- the connection spec -------------------------------------------------

(def- init-statements
  "Session settings that travel as one MYSQL_INIT_COMMAND, in a stable
  order."
  [[:time-zone "time_zone"] [:sql-mode "sql_mode"]])

(def- setting-value-peg
  # A time zone is "+00:00" or "America/New_York"; a sql_mode is a
  # comma-separated list of MODE_NAMES. Neither has any business
  # containing a quote, a backslash or a semicolon
  (peg/compile ~(* (some (+ (range "az" "AZ" "09") (set "_-+:/., "))) -1)))

(defn- setting-value
  ``One named session setting's value, quoted for the statement it
  goes into.

  Restricted rather than escaped, which is the same decision
  void/db-postgres/config makes about backend options and for a
  better reason here: this statement runs as MYSQL_INIT_COMMAND,
  before there is a connection to call `mysql_real_escape_string` on,
  so the escaping would have to be written by hand. Doubling the
  quote is not enough on its own — MySQL also reads a backslash as an
  escape inside a string literal, so `\'` would close the literal
  that `''` was meant to keep open — and a config value that reaches
  a statement uninspected is a config value an environment variable
  can write. The settings that genuinely need exotic text belong in
  [:init-command], which is a statement its author wrote.``
  [name v]
  (def s (string v))
  (unless (peg/match setting-value-peg s)
    (errorf (string "mysql: %s = %q is not a plain setting value (letters, "
                    "digits and _-+:/., only) — put it in "
                    "[:db-mysql :init-command] as a statement of your own")
            name v))
  (string "'" s "'"))

(defn init-command
  ``The MYSQL_INIT_COMMAND for a slice: the statement the server runs
  as the session opens, and again on every reconnect the library
  makes. :time-zone and :sql-mode become one SET, and
  [:init-command] is appended verbatim for whatever else a
  deployment needs.``
  [cfg]
  (def parts @[])
  (def sets @[])
  (each [k name] init-statements
    (when-let [v (get cfg k)]
      (array/push sets (string name " = " (setting-value name v)))))
  (unless (empty? sets)
    (array/push parts (string "SET SESSION " (string/join sets ", "))))
  (when-let [c (get cfg :init-command)] (array/push parts c))
  (unless (empty? parts) (string/join parts "; ")))

(defn spec
  ``The plain-data connection spec for a [:db-mysql] slice — what
  crosses into a worker thread (./worker's `connect!` takes exactly
  this). Marshalable by construction: strings, numbers, booleans and
  keywords, and nothing else.``
  [cfg0]
  (def given (or cfg0 {}))
  (def from-url (if-let [u (get given :url)] (parse-url u) {}))
  # explicit keys beat the URL, and both beat the fallbacks — in that
  # order, which is the order `merge` reads them in
  (def cfg (merge fallbacks from-url given))
  # the host is resolved by hand rather than out of `cfg`, because
  # MYSQL_HOST has to sit between "nobody said" and the fallback
  (def named-host (or (get given :host) (get from-url :host)))
  (def out
    @{:host (or named-host (os/getenv host-env) (fallbacks :host))
      :port (get cfg :port)
      :socket (get cfg :socket)
      :database (get cfg :database)
      :user (get cfg :user)
      :password (get cfg :password)
      :charset (get cfg :charset)
      :library (get cfg :library)
      :connect-timeout (get cfg :connect-timeout)
      :read-timeout (get cfg :read-timeout)
      :write-timeout (get cfg :write-timeout)
      :found-rows (not= false (get cfg :found-rows))
      :ssl-mode (get cfg :ssl-mode)
      :ssl-ca (get cfg :ssl-ca)
      :ssl-cert (get cfg :ssl-cert)
      :ssl-key (get cfg :ssl-key)
      :decode (let [d @{}]
                (each k [:json :booleans]
                  (unless (nil? (get cfg k)) (put d k (get cfg k))))
                (table/to-struct d))})
  (when-let [c (init-command cfg)] (put out :init-command c))
  # a unix socket and a host are alternatives, and the library reaches
  # for the socket only when the host is absent or "localhost". A
  # configured socket with nobody having named a host therefore means
  # the socket — leaving the default host in would quietly send the
  # connection over TCP instead
  (when (and (get out :socket) (nil? named-host))
    (put out :host nil))
  (table/to-struct out))

(defn describe
  ``The connection as a handful of values for a log line or a health
  report: {:host :port :socket :database :user :charset :ssl-mode},
  with no secret among them. \"Which server did it connect to\" is the
  question a log line is there to answer.``
  [cfg]
  (def s (spec cfg))
  (def out @{})
  # :charset is deliberately absent: what a connection actually
  # negotiated is in `worker/info`, and printing a configured value
  # beside it invites reading the wrong one as the truth
  (each k [:host :port :socket :database :user :ssl-mode]
    (when-let [v (get s k)] (put out k v)))
  (table/to-struct out))

(defn safe-url
  ``A connection URL with the password removed — what gets logged when
  a slice was configured with one. The rest stays: a URL with its
  secret masked is still the fastest way to see where a process
  pointed.

  The masking is done on the raw string and not on the parsed
  password, because the two are not the same text: a password with an
  @ in it arrives percent-escaped, and replacing the decoded form
  would find nothing and log the secret.``
  [url]
  (def scheme (find |(string/has-prefix? $ url) url-schemes))
  (unless scheme (break url))
  (def head (length scheme))
  (def body (string/slice url head))
  (def [before-query] (split-once body "?"))
  (def [authority] (split-once before-query "/"))
  (def at (last (string/find-all "@" authority)))
  (unless at (break url))
  (def userinfo (string/slice authority 0 at))
  (def colon (string/find ":" userinfo))
  (unless colon (break url))
  (string scheme (string/slice userinfo 0 colon) ":***"
          (string/slice body at)))
