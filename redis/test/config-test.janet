(import ../test-support/paths)
(import void/redis/config :as config)
(import void/redis/conn :as conn)
(import void/core/schema :as schema)

# -- the slice validates -------------------------------------------------

(assert (schema/valid? config/Config config/defaults)
        "the declared defaults satisfy the declared schema")
(assert (schema/valid? config/Config {:url "redis://x" :pool {:size 4}}))
(assert (not (schema/valid? config/Config {:port 0})) "a port is a port")
(assert (not (schema/valid? config/Config {:protocol 4})) "RESP4 does not exist yet")
(assert (not (schema/valid? config/Config {:pool {:size 0}})) "a pool holds at least one")

# -- urls ----------------------------------------------------------------

(assert (deep= @{:host "cache.internal" :port 6380 :database 2
                 :username "user" :password "p@ss"}
               (config/parse-url "redis://user:p%40ss@cache.internal:6380/2"))
        "a full url, with the escape a password containing @ needs")
(assert (deep= @{:host "host"} (config/parse-url "redis://host"))
        "and a url that says only where")
(assert (deep= @{:host "127.0.0.1" :password "secret"}
               (config/parse-url "redis://:secret@127.0.0.1"))
        "a password with no user is the classic requirepass")
(assert (deep= @{:host "::1" :port 6379 :database 0}
               (config/parse-url "redis://[::1]:6379/0"))
        "an IPv6 literal keeps its brackets out of the host")
(assert (deep= @{:unix "/run/redis.sock" :database 1}
               (config/parse-url "unix:///run/redis.sock?db=1"))
        "a socket path survives the parse whole")
(assert (= "worker" ((config/parse-url "redis://h/1?client_name=worker") :client-name))
        "query parameters carry the settings a url customarily does")

# rediss:// parses into {:tls true} — whether the composition can honour
# that is decided where the socket opens: with no :void/tls the connection
# refuses loudly, it never downgrades
(assert (deep= @{:host "cache" :tls true}
               (config/parse-url "rediss://cache"))
        "rediss:// is the same url with :tls true")
(def [tok terr] (protect (conn/open {:host "127.0.0.1" :port 1 :tls true})))
(assert (not tok) "a :tls target without void/tls is refused before any socket opens")
(assert (string/find ":void/tls" (string terr)) "naming the plugin as the way in")
(assert (not (first (protect (config/parse-url "redis://h/?bogus=1"))))
        "an unknown parameter is an error, not a dropped instruction")
(assert (not (first (protect (config/parse-url "http://h")))) "and so is another scheme")
(assert (not (first (protect (config/parse-url "redis://h/notanumber"))))
        "a path that is not a database number is not a database number")

# -- the slice as connection options -------------------------------------

(assert (= 3 ((config/options {:url "redis://cache:6380/0" :database 3}) :database))
        "an explicit key beats the same key inside the url")
(assert (= "cache" ((config/options {:url "redis://cache:6380/0" :database 3}) :host))
        "and leaves the rest of the url alone")
(assert (= "127.0.0.1" ((config/options {}) :host)) "an empty slice is a local server")
(assert (nil? ((config/options {:unix "/tmp/r.sock"}) :host))
        "a socket and a host are alternatives: the defaulted host is dropped")
(assert (nil? ((config/options {}) :prefix))
        "the prefix belongs to the client, not to a socket")

(def d (config/describe {:url "redis://u:secret@h:1/2" :prefix "app:"}))
(assert (= "h:1" (d :server)))
(assert (= 2 (d :database)))
(assert (= "app:" (d :prefix)))
(each v d
  (assert (not (and (string? v) (string/find "secret" v)))
          "a password never reaches the description a log prints"))

(assert (= 8 ((config/pool-options {}) :size)) "the pool has a default size")
(assert (= 4 ((config/pool-options {:pool {:size 4}}) :size)) "which the slice overrides")

(printf "config-test: ok")
