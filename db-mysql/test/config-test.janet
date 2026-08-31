(import ../test-support/paths)
(import void/db-mysql/config :as config)

# What this file is about: no client library, no server, no network.
# Turning a config slice into a connection spec is pure data work, and
# it is where the mistakes that cost an afternoon live — a password
# with an @ in it, a socket that quietly went over TCP, a secret that
# reached a log line.

# -- URLs ----------------------------------------------------------------

(assert (config/url? "mysql://db/app"))
(assert (config/url? "mariadb://db/app") "MariaDB's own spelling means the same thing")
(assert (not (config/url? "host=db database=app")))

(def full (config/parse-url "mysql://void:s3cret@db.internal:3307/app?ssl-mode=required"))
(assert (= "void" (full :user)))
(assert (= "s3cret" (full :password)))
(assert (= "db.internal" (full :host)))
(assert (= 3307 (full :port)) "a port is a number here, not a string — the C call takes one")
(assert (= "app" (full :database)))
(assert (= :required (full :ssl-mode))
        "an enum parameter arrives as the keyword the schema declares")

(assert (empty? (config/parse-url "mysql://"))
        "a URL may carry nothing at all")
(assert (= "app" ((config/parse-url "mysql:///app") :database))
        "and it may carry only the database, over the local socket")

# the parts that are actually hard

(def escaped (config/parse-url "mysql://us%65r:p%40ss%2Fword@db/my%20app"))
(assert (= "user" (escaped :user)) "percent-escapes are decoded")
(assert (= "p@ss/word" (escaped :password))
        "including the two that would otherwise be delimiters")
(assert (= "my app" (escaped :database)))

(assert (= "db" ((config/parse-url "mysql://void:pa@ss@db/app") :host))
        "the userinfo boundary is the LAST @, so a password may contain one")
(assert (= "pa@ss" ((config/parse-url "mysql://void:pa@ss@db/app") :password)))

(def v6 (config/parse-url "mysql://void@[2001:db8::1]:3307/app"))
(assert (= "2001:db8::1" (v6 :host)) "an IPv6 literal is bracketed and unbracketed again")
(assert (= 3307 (v6 :port)))

(def sock (config/parse-url "mysql://void@/app?socket=/tmp/mysql.sock"))
(assert (= "/tmp/mysql.sock" (sock :socket))
        "a socket path cannot go in the authority, so it is a query parameter")
(assert (nil? (sock :host)))

(assert (= false ((config/parse-url "mysql://db/app?found-rows=false") :found-rows))
        "a boolean parameter is a boolean, not the string \"false\"")
(assert (= 3 ((config/parse-url "mysql://db/app?connect-timeout=3") :connect-timeout)))

(def [ok err] (protect (config/parse-url "mysql://db/app?sslmodee=required")))
(assert (not ok) "an unknown URL parameter is a typo, and a typo about TLS is worth refusing")
(assert (string/find "not a connection URL parameter" err))

(assert (not (first (protect (config/parse-url "mysql://db/app?found-rows=maybe"))))
        "and neither is a boolean that is not one")
(assert (not (first (protect (config/parse-url "postgres://db/app"))))
        "another engine's URL is not read as this one's")
(assert (not (first (protect (config/parse-url "mysql://us%zzr@db/app"))))
        "a broken percent-escape is a typo, not a hostname")

# -- precedence ----------------------------------------------------------

(def merged (config/spec {:url "mysql://void:s3cret@db:3307/app" :user "importer"}))
(assert (= "importer" (merged :user)) "an explicit key beats the same key inside the URL")
(assert (= "s3cret" (merged :password)) "and leaves the rest of the URL alone")
(assert (= "db" (merged :host)))
(assert (= 3307 (merged :port)))

# the plugin declares NO config defaults, on purpose: the kernel merges
# those into the slice before this module sees it, and a merged default
# is indistinguishable from a choice — :port 3306 as a config default
# would quietly beat the :3307 in a deployment's own connection URL
(assert (empty? config/defaults)
        "the [:db-mysql] slice has no kernel-merged defaults, and config/defaults says why")
(def url-port (config/spec {:url "mysql://db:3307/app"}))
(assert (= 3307 (url-port :port))
        "so a port that only the URL names is the port that is used")

(def bare (config/spec {}))
(assert (= "127.0.0.1" (bare :host)) "the fallback is a real localhost")
(assert (= 3306 (bare :port)))
(assert (= "utf8mb4" (bare :charset))
        (string "utf8mb4 by default: MySQL's \"utf8\" cannot store an emoji, "
                "and the charset is what the parameter escaping is correct against"))
(assert (= true (bare :found-rows))
        "and an UPDATE counts what it matched, which is what the other drivers report")

# -- sockets -------------------------------------------------------------

(def only-socket (config/spec {:socket "/tmp/mysql.sock" :database "app"}))
(assert (nil? (only-socket :host))
        (string "a configured socket with nobody naming a host means the socket "
                "— leaving the default host in would quietly send it over TCP"))
(assert (= "/tmp/mysql.sock" (only-socket :socket)))

(def both (config/spec {:host "db" :socket "/tmp/mysql.sock"}))
(assert (= "db" (both :host))
        (string "but a host that WAS named stays: the library then prefers it, "
                "and that is the caller's choice to make"))

# -- session settings ----------------------------------------------------

(assert (nil? (config/init-command {})) "nothing to set, nothing sent")
(assert (= "SET SESSION time_zone = '+00:00'"
           (config/init-command {:time-zone "+00:00"})))
(assert (= "SET SESSION time_zone = '+00:00', sql_mode = 'TRADITIONAL'"
           (config/init-command {:time-zone "+00:00" :sql-mode "TRADITIONAL"}))
        "the named settings become one statement, in a stable order")
(assert (= "SET SESSION time_zone = 'UTC'; SET autocommit = 1"
           (config/init-command {:time-zone "UTC" :init-command "SET autocommit = 1"}))
        "and [:init-command] is appended for whatever else a deployment needs")
(assert (not (first (protect (config/init-command {:time-zone "\\'; DROP"}))))
        (string "a named setting's value is restricted, not escaped: this "
                "statement runs as MYSQL_INIT_COMMAND, before there is a "
                "connection to escape against, and doubling the quote alone "
                "would not survive the backslash in front of it"))
(assert (not (first (protect (config/init-command {:sql-mode "TRADITIONAL'; DROP TABLE t"}))))
        "the same for sql_mode")
(assert (= "SET SESSION time_zone = 'America/New_York'"
           (config/init-command {:time-zone "America/New_York"}))
        "while the values these settings actually take go through")
(assert (= "SET SESSION sql_mode = 'STRICT_ALL_TABLES,NO_ZERO_DATE'"
           (config/init-command {:sql-mode "STRICT_ALL_TABLES,NO_ZERO_DATE"})))

(def with-init (config/spec {:time-zone "UTC"}))
(assert (= "SET SESSION time_zone = 'UTC'" (with-init :init-command)))

# -- what may be logged --------------------------------------------------

(def described (config/describe {:url "mysql://void:s3cret@db:3307/app"}))
(assert (= "db" (described :host)))
(assert (nil? (described :charset))
        (string "the charset is not described: what a connection negotiated is "
                "worker/info's answer, and a configured value printed beside it "
                "invites reading the wrong one as the truth"))
(assert (= "app" (described :database)))
(assert (= "void" (described :user)))
(assert (nil? (described :password))
        "the description is what goes in a log line, and a password never does")

(assert (= "mysql://void:***@db:3307/app?charset=utf8mb4"
           (config/safe-url "mysql://void:s3cret@db:3307/app?charset=utf8mb4"))
        "a logged URL keeps everything but the secret")
(assert (= "mysql://void:***@db/app"
           (config/safe-url "mysql://void:s3%40cret@db/app"))
        (string "including when the password is percent-escaped — masking the "
                "DECODED password would find nothing and log the real one"))
(assert (= "mysql://db/app" (config/safe-url "mysql://db/app"))
        "and a URL with no password is left alone")

# -- the spec is marshalable, which is the whole point -------------------
#
# It crosses into another VM (ADR-0033). Anything in it that could not
# be marshalled would be a runtime failure on a worker thread, which is
# the least debuggable place in this package.

(def spec (config/spec {:url "mysql://void:s3cret@db:3307/app?ssl-mode=required"
                        :time-zone "UTC" :json false}))
(assert (deep= spec (unmarshal (marshal spec)))
        (string "the connection spec survives a round trip through marshal, "
                "because a worker thread is a separate VM and that is how it "
                "gets there"))

(print "db-mysql config-test ok")
