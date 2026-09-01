### void/redis — the redis client plugin (SPEC.md §5.10).
###
### RESP2 and RESP3 in pure Janet on the ev loop: a connection is a
### `net/` stream and a buffer, so there is no native module here, no
### thread pool, and no blocking call on the loop (ADR-0010). What
### lives where:
###
###   ./resp      the wire format — the scanner and the PEG
###   ./config    [:redis] -> what one connection opens with
###   ./conn      one connection: handshake, call, pipeline, framing
###   ./pool      the fiber-aware pool
###   ./codec     value codecs, and the :void.redis/codec point
###   ./state     current client, dyn-scoped connections, the funnel
###   ./commands  the command surface applications import
###   ./pubsub    publish/subscribe on a connection of its own
###
### Two components. `:redis/client` is the pool and everything above
### it; `:redis/pubsub` is the subscriber, which is a separate
### component because it is a separate connection and because an
### application that does not subscribe should not have one.
###
###     (void/run! {:plugins [:void/redis ...]})
###     # config/prod.janet
###     {:redis {:url "redis://cache.internal:6379/0"
###              :prefix "myapp:" :codec :jdn
###              :pool {:size 16}}}
###
### Applications import `void/redis` and nothing below it:
###
###     (import void/redis :as redis)
###     (redis/set "greeting" "hello" {:ex 60})
###     (redis/get "greeting")
###     (redis/remember "rates" 300 fetch-rates)
###
### Sessions in redis are the companion plugin `void/redis-http`
### (./http) — the one piece that needs void/http, kept separate so a
### CLI or a worker never drags the HTTP kernel in, exactly as
### void/db-http is to void/db.
###
### What this plugin deliberately does not do: TLS (ADR-0010 — put a
### proxy in front, or use a unix socket; `rediss://` says so rather
### than pretending), Cluster and Sentinel (both are a different
### client — MOVED/ASK redirection and a topology to track — and both
### want their own ADR), and the `:void/cache` and
### `:void/queue-backend` interfaces, which arrive with the plugins
### that define them in 2.3 and 2.4. The primitives those are built out
### of are all here: TTLs, atomic counters, `SET NX` locks, sorted sets
### for delayed work, blocking pops, and Lua scripts for the steps that
### must be one step.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./codec :as codec)
(import ./commands :as commands)
(import ./config :as config)
(import ./conn :as conn)
(import ./pool :as pool)
(import ./pubsub :as pubsub)
(import ./resp :as resp)
(import ./state :as state)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.redis")

# -- the interface and the codec point -----------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/redis
   :doc "A redis client: the :redis/client component's value ({:pool :codec :prefix}), which void/redis's own functions reach through state/active-client. Depend on the interface rather than the key to let a test stand a stub in its place."
   :methods {:pool "the connection pool (see void/redis/pool)"
             :codec "the value codec named by [:redis :codec]"
             :prefix "the string every key is prefixed with"}})

(plugin/defextension-point :void.redis/codec
  :doc "Value codecs: {:name :encode (fn [value] bytes) :decode (fn [bytes] value)}; config [:redis :codec] picks one by name"
  :schema {:name :keyword :encode :function :decode :function}
  :validate (fn [contribs]
              (def seen @{})
              (def dupes @[])
              (each c contribs
                (if (in seen (c :name))
                  (array/push dupes (c :name))
                  (put seen (c :name) true)))
              (unless (empty? dupes)
                (errorf "duplicate redis codec %s"
                        (string/join (map |(string/format "%q" $) dupes) " "))))
  :reduce (fn [contribs] (tabseq [c :in contribs] (c :name) c)))

(each c codec/builtin (plugin/contribute! :void.redis/codec c))

# -- public surface (re-exports) -----------------------------------------

(def Config "Schema of the [:redis] config slice." config/Config)
(def defaults "Defaults of the [:redis] slice." config/defaults)
(def parse-url "See config/parse-url — a redis:// url as config keywords." config/parse-url)
(def connection-options "See config/options — the slice as connection options." config/options)

(def open-connection "See conn/open — one connection, outside the pool." conn/open)
(def close-connection "See conn/close." conn/close)
(def connection-info "See conn/info." conn/info)
(def error? "See conn/error? — is this value a redis error?" conn/error?)
(def error-code "See conn/error-code — \"WRONGTYPE\", \"NOSCRIPT\", \"MOVED\"." conn/error-code)
(def fatal-error? "See conn/fatal? — did the connection break, or just the command?" conn/fatal?)

(def encode-command "See resp/encode — a command as RESP bytes." resp/encode)
(def parse-reply "See resp/parse — RESP bytes as [value end]." resp/parse)

(def pool-stats "See pool/stats — checkouts, waits, command timing." pool/stats)

(def client-dyn "See state/client-dyn — the client override." state/client-dyn)
(def conn-dyn "See state/conn-dyn — the checked-out connection." state/conn-dyn)
(def active-client "See state/active-client." state/active-client)
(def with-conn* "See state/with-conn*." state/with-conn*)
(defmacro with-conn
  ``Run the body on one connection (see state/with-conn) — MULTI/EXEC,
  WATCH, or anything else that means "the same session".``
  [& body]
  ~(,state/with-conn* (fn with-conn-body [_] ,;body)))

(def command "See commands/command — one command, raw." commands/command)
(def call "See state/call — one command as an array, with options." state/call)
(def pipeline "See conn/pipeline — several commands, one round trip." state/pipeline)
(def redis-key "See state/prefixed — a key as it reaches the server." state/prefixed)

(def del-keys "See commands/del-keys." commands/del-keys)
(def exists? "See commands/exists?." commands/exists?)
(def expire "See commands/expire — set a time to live." commands/expire)
(def persist "See commands/persist — remove the expiry." commands/persist)
(def rename "See commands/rename." commands/rename)
(def incr "See commands/incr." commands/incr)
(def decr "See commands/decr." commands/decr)
(def incr-float "See commands/incr-float." commands/incr-float)
(def mget "See commands/mget." commands/mget)
(def mset "See commands/mset." commands/mset)
(def hget "See commands/hget." commands/hget)
(def hset "See commands/hset — one field, or a whole dictionary." commands/hset)
(def hdel "See commands/hdel." commands/hdel)
(def hgetall "See commands/hgetall — a hash as a table." commands/hgetall)
(def hincr "See commands/hincr." commands/hincr)
(def hkeys "See commands/hkeys." commands/hkeys)
(def hlen "See commands/hlen." commands/hlen)
(def lpush "See commands/lpush." commands/lpush)
(def rpush "See commands/rpush." commands/rpush)
(def lpop "See commands/lpop." commands/lpop)
(def rpop "See commands/rpop." commands/rpop)
(def llen "See commands/llen." commands/llen)
(def lrange "See commands/lrange." commands/lrange)
(def ltrim "See commands/ltrim." commands/ltrim)
(def blpop "See commands/blpop — a blocking pop from the head." commands/blpop)
(def brpop "See commands/brpop — a blocking pop from the tail." commands/brpop)
(def sadd "See commands/sadd." commands/sadd)
(def srem "See commands/srem." commands/srem)
(def smembers "See commands/smembers." commands/smembers)
(def smember? "See commands/smember?." commands/smember?)
(def scard "See commands/scard." commands/scard)
(def zadd "See commands/zadd." commands/zadd)
(def zrem "See commands/zrem." commands/zrem)
(def zscore "See commands/zscore." commands/zscore)
(def zcard "See commands/zcard." commands/zcard)
(def zrange "See commands/zrange." commands/zrange)
(def zrange-by-score "See commands/zrange-by-score." commands/zrange-by-score)
(def scan-each "See commands/scan-each — walk the keyspace with SCAN." commands/scan-each)
(def script "See commands/script — a Lua script as a callable." commands/script)
(def remember "See commands/remember — read-through cache." commands/remember)
(def forget "See commands/forget — drop cached keys." commands/forget)
(def ping "See commands/ping." commands/ping)
(def server-info "See commands/server-info — INFO as a table." commands/server-info)
(def dbsize "See commands/dbsize." commands/dbsize)
(def flushdb! "See commands/flushdb! — delete every key in the database." commands/flushdb!)

# -- the client component ------------------------------------------------

(var current-boot
  ``Boot value, captured at :before-start — the codecs contributed to
  :void.redis/codec are read off it, and the profile decides whether a
  missing server is worth a warning.``
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :redis/capture-boot
   :doc "Remember the boot value — the resolved codecs and the profile"
   :fn (fn capture [boot] (set current-boot boot))})

(defn contributed-codecs
  "The resolved :void.redis/codec point: name -> codec."
  []
  (or (get-in current-boot [:extensions :void.redis/codec :resolved])
      # started outside a bootstrap (a test, a REPL): the built-ins are
      # what the point would have resolved to anyway
      (tabseq [c :in codec/builtin] (c :name) c)))

(def client-component
  (system/component :redis/client
    :doc "The redis client: a fiber-aware pool of RESP connections,
    the configured codec and key prefix. Holds one connection open
    from :start to :stop outside the pool, so a wrong host or a
    refused password fails the boot rather than the first request —
    and so the health check has a connection to use that no request is
    waiting on."
    :provides [:void/redis]
    :config {:key :redis :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (merge config/defaults (or cfg0 {})))
      (def conn-opts (config/options cfg0))
      (def codecs (contributed-codecs))
      (def chosen (codec/find-codec codecs (get cfg :codec :raw)))
      (def p (pool/make conn-opts (config/pool-options cfg0)))
      # the keeper proves the configuration before anything depends on
      # it, and answers the health check without borrowing from the pool
      (def keeper (conn/open conn-opts))
      (def info (conn/info keeper))
      (log/info "redis client ready" :ns log-ns
                :server (info :server)
                :version (info :server-version)
                :protocol (info :protocol)
                :database (info :database)
                :codec (chosen :name)
                :prefix (get cfg :prefix "")
                :pool (get-in cfg [:pool :size]))
      (when (and (= 2 (info :protocol)) (>= (get cfg :protocol 3) 3))
        (log/debug "the server has no HELLO — RESP2 it is" :ns log-ns
                   :version (info :server-version)))
      (def value
        @{:pool p
          :keeper keeper
          :codec chosen
          :codecs codecs
          :prefix (get cfg :prefix "")
          :session-prefix (get-in cfg [:session :prefix] "session:")
          :retry (not= false (get cfg :retry))
          :conn-opts conn-opts
          :describe (config/describe cfg0)})
      (set state/current-client value)
      value)
    :stop
    (fn stop [client]
      (set state/current-client nil)
      (pool/close-all! (client :pool))
      (protect (conn/close (client :keeper))))
    :health
    (fn health [client]
      (def keeper (client :keeper))
      (def [ok] (protect (conn/ping keeper)))
      (merge {:status (if ok :up :down)}
             (client :describe)
             (pool/stats (client :pool))
             {:server-version (get (conn/info keeper) :server-version)}))))

# -- the subscriber component --------------------------------------------

(var current-pubsub
  "The started :redis/pubsub component, for `subscribe!`."
  nil)

(defn pubsub-now
  "The running subscriber, or an error naming what to add."
  []
  (or current-pubsub
      (error "void/redis's subscriber is not started — no :redis/pubsub component (is [:redis :pubsub :enabled] false?)")))

(defn subscribe!
  ``Call `f` with every message published to `channel`
  ({:channel :payload}). Returns `f`, which `unsubscribe!` takes back.

      (redis/subscribe! "cache-invalidation"
                        (fn [m] (cache/forget! (m :payload))))

  The subscription lives on the subscriber's own connection, not on a
  pooled one. Handlers run in the reading fiber: keep them short, and
  start a fiber of your own for anything that touches redis.``
  [channel f]
  (pubsub/subscribe! (pubsub-now) channel f))

(defn psubscribe!
  "Like `subscribe!`, for a glob pattern (`user:*:events`)."
  [pattern f]
  (pubsub/psubscribe! (pubsub-now) pattern f))

(defn unsubscribe!
  "Remove one handler, or all of a channel's when `f` is omitted."
  [channel &opt f]
  (pubsub/unsubscribe! (pubsub-now) channel f))

(defn punsubscribe!
  "Remove one pattern handler, or all of a pattern's."
  [pattern &opt f]
  (pubsub/punsubscribe! (pubsub-now) pattern f))

(defn publish!
  ``Publish a message, through the pool. Returns how many subscribers
  the server handed it to — which is the only delivery signal redis
  pub/sub has, and it counts connections, not handlers, and not
  anything that succeeded.``
  [channel message]
  (state/call ["PUBLISH" (string channel) (state/codec-encode message)]))

(def pubsub-component
  (system/component :redis/pubsub
    :doc "Publish/subscribe on a connection of its own, outside the
    pool — a subscribed connection cannot serve ordinary commands, and
    a pooled one is handed to whoever asks next. One fiber parked in a
    read; the connection is opened by the first subscription, so an
    application that never subscribes never opens one."
    :deps [:redis/client]
    :config {:key :redis :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (merge config/defaults (or cfg0 {})))
      (def client (get deps :redis/client))
      (def enabled (not= false (get-in cfg [:pubsub :enabled])))
      (def l (pubsub/open (config/options cfg0)
                          {:codec (client :codec)
                           :backoff (get-in cfg [:pubsub :backoff] {})}))
      (put l :enabled enabled)
      # disabled, the component still exists (a graph that changes
      # shape with a config value is a graph nobody can read) — it
      # simply never reads, and `subscribe!` says which key turned it
      # off rather than failing on a connection that was never opened
      (when enabled
        (pubsub/start! l)
        (set current-pubsub l))
      l)
    :stop
    (fn stop [l]
      (set current-pubsub nil)
      (pubsub/stop! l))
    :health
    (fn health [l]
      (if (l :enabled)
        (merge {:status (if (pubsub/running? l) :up :down)} (pubsub/stats l))
        {:status :up :enabled false}))))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :redis/info
   :read-only? true
   :doc "Show what the redis client connected to: void redis info"
   :needs [:redis/client]
   # :needs instances come first, then the string arguments
   :fn (fn cli-info [client & args]
         (unless (empty? args)
           (errorf "void redis info takes no arguments (got %q)" (string/join args " ")))
         (def info (conn/info (client :keeper)))
         (printf "server      %s" (info :server))
         (printf "version     %s" (or (info :server-version) "(RESP2: the server has no HELLO)"))
         (printf "protocol    RESP%d" (info :protocol))
         (printf "database    %d" (info :database))
         (printf "role        %s" (or (info :role) "-"))
         (printf "codec       %q" (get-in client [:codec :name]))
         (printf "prefix      %q" (client :prefix))
         (def s (pool/stats (client :pool)))
         (printf "pool        size %d, open %d, in use %d, idle %d"
                 (s :size) (s :created) (s :in-use) (s :idle)))})

(plugin/contribute! :void.core/cli
  {:name :redis/ping
   :read-only? true
   :doc "PING the configured server: void redis ping"
   :needs [:redis/client]
   :fn (fn cli-ping [client & args]
         (unless (empty? args)
           (errorf "void redis ping takes no arguments (got %q)" (string/join args " ")))
         (def t0 (os/clock :monotonic))
         (conn/ping (client :keeper))
         (printf "PONG (%.2f ms)" (* 1000 (- (os/clock :monotonic) t0))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/redis
  :doc "The redis client: RESP2/RESP3 in pure Janet on the ev loop — a fiber-aware pool, pipelining, Lua scripts, and pub/sub on a connection of its own. No native code, no thread pool."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :redis
  :config-schema Config
  :config-defaults defaults
  :components [client-component pubsub-component])

# -- names that shadow the core ------------------------------------------
#
# Last, and deliberately: `get`, `set`, `keys` and `type` are core
# functions, and a module that shadows them before its own code is
# written is a module that cannot use them. Everything above is
# defined; from here nothing is.

(def get "See commands/get-key — the value of a key, decoded." commands/get-key)
(def set "See commands/set-key — set a key, with :ex/:nx/:xx/:get." commands/set-key)
(def del "See commands/del-keys — delete keys." commands/del-keys)
(def keys "See commands/matching-keys — every key matching a glob, via SCAN." commands/matching-keys)
(def type "See commands/key-type — the type of a key, as a keyword." commands/key-type)
(def ttl "See commands/key-ttl — seconds to live, :none, or nil." commands/key-ttl)
