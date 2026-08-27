(import ../test-support/paths)
(import void/db-postgres/config :as config)

# What this file is about: no libpq, no server, no network. Building a
# connection string is pure string work, and it is where the mistakes
# that cost an afternoon live — a password with an @ in it, a URL whose
# port list libpq reads differently than you meant, a secret that
# reached a log line.

# -- URLs ----------------------------------------------------------------

(assert (config/url? "postgres://db/app"))
(assert (config/url? "postgresql://db/app"))
(assert (not (config/url? "host=db dbname=app")))

(def full (config/parse-url "postgres://void:s3cret@db.internal:6432/app?sslmode=require&connect_timeout=3"))
(assert (= "void" (full :user)))
(assert (= "s3cret" (full :password)))
(assert (= "db.internal" (full :host)))
(assert (= "6432" (full :port)))
(assert (= "app" (full :database)))
(assert (= "require" (get-in full [:params "sslmode"]))
        "query parameters are libpq keywords and stay as they are")
(assert (= "3" (get-in full [:params "connect_timeout"])))

(assert (empty? (config/parse-url "postgres://"))
        "a URL may carry nothing at all — everything then comes from the environment")
(assert (= "app" ((config/parse-url "postgres:///app") :database))
        "and it may carry only the database, over the local socket")

# the parts that are actually hard

(def escaped (config/parse-url "postgres://us%65r:p%40ss%2Fword@db/my%20app"))
(assert (= "user" (escaped :user)) "percent-escapes are decoded")
(assert (= "p@ss/word" (escaped :password))
        "including the two that would otherwise be delimiters")
(assert (= "my app" (escaped :database)))

(assert (= "s3cret" ((config/parse-url "postgres://void:s3cret@db/app") :password)))
(assert (= "db" ((config/parse-url "postgres://void:pa@ss@db/app") :host))
        "the userinfo ends at the LAST @, so an unescaped one in a password still works")

(def six (config/parse-url "postgres://[2001:db8::1]:5433/app"))
(assert (= "2001:db8::1" (six :host)) "an IPv6 literal is unbracketed")
(assert (= "5433" (six :port)) "and its port is not part of it")

(def multi (config/parse-url "postgres://a:5432,b:5433,c/app"))
(assert (= "a,b,c" (multi :host)) "a multi-host URL keeps libpq's own spelling")
(assert (= "5432,5433," (multi :port))
        "with a port list of the same length — an empty entry means the default")

(each bad ["mysql://db/app" "db.internal/app"]
  (def [ok err] (protect (config/parse-url bad)))
  (assert (not ok) (string bad " is not a postgres url"))
  (assert (string/find "postgres://" err) "and the error says what one looks like"))

(def [ok err] (protect (config/parse-url "postgres://db/%zz")))
(assert (not ok) "a broken percent-escape is a typo worth reporting")
(assert (string/find "percent-escape" err))

# -- quoting -------------------------------------------------------------

(assert (= "'plain'" (config/quote-value "plain")))
(assert (= "'two words'" (config/quote-value "two words")))
(assert (= `'it\'s'` (config/quote-value "it's")) "a quote is escaped")
(assert (= `'a\\b'` (config/quote-value `a\b`)) "and so is a backslash")

# -- the keyword string --------------------------------------------------

(def plain (config/conninfo {:host "db" :port 5432 :database "app" :user "void"}))
(assert (string/find "host='db'" plain))
(assert (string/find "dbname='app'" plain) ":database is libpq's dbname")
(assert (string/find "port='5432'" plain) "a number becomes its text")
(assert (string/find "application_name='void'" plain)
        "the one default worth having: something to see in pg_stat_activity")

(assert (= (config/conninfo {:host "db"}) (config/conninfo {:host "db"}))
        "the same slice always builds the same string — a conninfo lands in logs and caches")

(assert (not (string/find "host=" (config/conninfo {})))
        "an empty slice mentions no host: libpq resolves PGHOST, the socket and ~/.pgpass exactly as psql would")

(def merged (config/conninfo {:url "postgres://url-user@url-host/url-db"
                              :user "explicit"}))
(assert (string/find "user='explicit'" merged) "an explicit key beats the URL's")
(assert (not (string/find "url-user" merged)) "and replaces it rather than joining it")
(assert (string/find "host='url-host'" merged) "what it does not mention still comes from the URL")
(assert (string/find "dbname='url-db'" merged))

# -- server-side settings ------------------------------------------------

(assert (nil? (config/options-value {})) "no settings, no options keyword")

(def opts (config/options-value {:statement-timeout 15000
                                 :search-path "app,public"
                                 :settings {:idle-session-timeout 60000}}))
(assert (= "-c statement_timeout=15000 -c search_path=app,public -c idle_session_timeout=60000"
           opts)
        "named settings first, then [:settings], each as a -c option")

(assert (string/find "options='-c statement_timeout=15000'"
                     (config/conninfo {:statement-timeout 15000}))
        "and they travel as one quoted libpq keyword")

(def [sok serr] (protect (config/options-value {:search-path "a, b"})))
(assert (not sok) "a value with a space in it is refused, not silently truncated")
(assert (string/find "SET" serr) "and the error says where such a value belongs")

# -- secrets -------------------------------------------------------------

(def secret {:url "postgres://void:hunter2@db/app"})
(assert (string/find "hunter2" (config/conninfo secret))
        "the real string carries the password")
(assert (not (string/find "hunter2" (config/safe-conninfo secret)))
        "the loggable one does not")
(assert (string/find "password='***'" (config/safe-conninfo secret))
        "but still says there was one — an absent password and a hidden one are different bugs")
(assert (string/find "user='void'" (config/safe-conninfo secret))
        "and everything that is not a secret stays readable")

(def described (config/describe secret))
(assert (nil? (get described :password)) "the health/log projection has no secret in it")
(assert (= "db" (described :host)))
(assert (= "app" (described :database)))
(assert (nil? (get (config/describe {}) :host))
        "a value libpq will resolve from the environment is absent, not guessed at")

# -- decoding options ----------------------------------------------------

(assert (deep= {} (config/decode-opts {})) "no decoding opinion by default")
(assert (deep= {:json false} (config/decode-opts {:json false}))
        "and false is an opinion, not an absence")

(print "db-postgres config: ok")
