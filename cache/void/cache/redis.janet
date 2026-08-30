### void/cache-redis — the cache in redis (SPEC.md §5.10 / §5.11,
### ROADMAP 2.3).
###
### The piece of void/cache that needs void/redis, kept a separate
### plugin so an application that caches in its own heap never loads a
### redis client — exactly what void/redis-http is to void/redis. Add
### it to the composition and say which store you mean:
###
###     (void/run! {:plugins [:void/redis :void/cache :void/cache-redis ...]})
###     # config/prod.janet
###     {:void/cache-store {:impl :cache/redis}
###      :cache {:prefix "myapp:" :ttl 600}
###      :redis {:url "redis://cache.internal/0"}}
###
### The `{:impl ...}` line is not boilerplate the plugin could have
### avoided: two components now provide `:void/cache-store`, and a
### kernel that picked one for you would be a kernel that picks
### differently the day a dependency changes. It is the same line two
### database drivers need, for the same reason.
###
### Three decisions worth stating.
###
### **The codec is this plugin's, not the client's.** `[:redis :codec]`
### defaults to `:raw` because *that* is the right default for a redis
### client — bytes another service can read. A cache holds whatever the
### application computed, tables and keywords included, and `:raw`
### cannot carry one, so `[:cache-redis :codec]` defaults to `:jdn` and
### is separate. Sessions made the same choice for the same reason. A
### deployment that really does want the cache readable by another
### language says `:json`; one that wants it readable by redis-cli says
### `:raw` and gets a store that declares `:values :bytes`, which is
### what stops a cached nil from coming back as text.
###
### **Clear walks, and never flushes.** The database this cache lives
### in belongs to whoever else is in it — sessions, queues, another
### application's keys — so `clear` SCANs for the cache's own prefix
### and deletes what it finds, in batches. It is O(keyspace) rather
### than O(1), it is not atomic, and a key written while it walks may
### outlive it; all three are worth it next to a FLUSHDB that takes
### somebody's sessions with it.
###
### **The counter's expiry is set when the counter is created**, not
### refreshed on every increment: a rate-limit window that slid with
### each request would never close. Two processes creating it in the
### same instant both set it, to the same value.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/redis/codec :as rcodec)
(import void/redis/commands :as rcmd)
(import void/redis/state :as redis)
(import ./store :as store)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.cache.redis")

(def Config
  "Schema of the [:cache-redis] config slice."
  {:codec [:optional :keyword]
   # how much work one SCAN round trip does while `clear` walks; a
   # hint to the server, not a page size
   :scan-count [:optional [:int {:min 1}]]})

(def defaults
  "Defaults of the [:cache-redis] slice."
  {:codec :jdn
   :scan-count 500})

(def delete-batch
  "How many keys one DEL takes while clearing. Large enough that the
  walk is not a round trip per key, small enough that the command does
  not become the thing that blocks the server."
  256)

(defn- glob-quote
  ``A key prefix as a SCAN pattern that matches it literally: a prefix
  containing a glob character is a prefix, not a pattern, and a
  `clear` that treated `myapp[1]:` as a character class would delete
  the wrong keys or none at all.``
  [s]
  (def out @"")
  (each c s
    (when (index-of c [(chr "*") (chr "?") (chr "[") (chr "]") (chr "\\") (chr "^")])
      (buffer/push-byte out (chr "\\")))
    (buffer/push-byte out c))
  (string out))

(defn- ms [ttl]
  (max 1 (math/round (* 1000 ttl))))

(defn make
  ``A `:void/cache-store` over the running redis client. Options:

    :codec       a codec from the :void.redis/codec registry
    :scan-count  SCAN hint for `clear`

  Nothing is captured but the codec: which server, which database and
  which key prefix are read off the client at call time, so the store
  outlives a restart of the client under it.``
  [opts]
  (def codec (opts :codec))
  (def scan-count (get opts :scan-count (defaults :scan-count)))
  (defn encode [v] (rcodec/encode codec v))
  (defn decode [v] (rcodec/decode codec v))
  {:name :redis
   # the point of this backend: one set of entries for every worker
   # and every machine, so `cache/forget` means what it says
   :shared? true
   # a codec that does not round-trip Janet values says so, and
   # ./state refuses to store a sentinel through it
   :values (if (= :raw (codec :name)) :bytes :janet)
   :codec (codec :name)

   :get (fn redis-get [k] (decode (redis/call ["GET" (redis/prefixed k)])))

   :put (fn redis-put [k v ttl]
          (def key (redis/prefixed k))
          (redis/call (if ttl
                        ["SET" key (encode v) "PX" (ms ttl)]
                        ["SET" key (encode v)]))
          v)

   :delete (fn redis-delete [k]
             (pos? (redis/call ["DEL" (redis/prefixed k)])))

   :has? (fn redis-has? [k]
           (pos? (redis/call ["EXISTS" (redis/prefixed k)])))

   :get-many (fn redis-get-many [ks]
               (if (empty? ks)
                 @[]
                 (map decode (redis/call ["MGET" ;(map redis/prefixed ks)]))))

   :put-many (fn redis-put-many [entries ttl]
               (unless (empty? entries)
                 (redis/pipeline
                   (seq [[k v] :in entries]
                     (if ttl
                       ["SET" (redis/prefixed k) (encode v) "PX" (ms ttl)]
                       ["SET" (redis/prefixed k) (encode v)]))))
               nil)

   # INCRBY is the reason a shared counter is exact here and only
   # process-local through the store fallback
   :incr (fn redis-incr [k delta ttl]
           (def key (redis/prefixed k))
           (def n (redis/call ["INCRBY" key delta]))
           (when (and ttl (= n delta))
             (redis/call ["PEXPIRE" key (ms ttl)]))
           n)

   :clear (fn redis-clear [prefix]
            (def doomed @[])
            (var n 0)
            (defn flush-batch []
              (unless (empty? doomed)
                (+= n (rcmd/del-keys ;doomed))
                (array/clear doomed)))
            (rcmd/scan-each
              (fn [k]
                (array/push doomed k)
                (when (>= (length doomed) delete-batch) (flush-batch)))
              {:match (string (glob-quote (or prefix "")) "*") :count scan-count})
            (flush-batch)
            n)

   :stats (fn redis-stats [] {:store :redis :codec (codec :name)})

   # the pool belongs to the redis client component, which closes it
   :close (fn redis-close [] nil)})

# -- the component -------------------------------------------------------

(defn- pick-codec [client name]
  (def registry (or (get client :codecs)
                    (tabseq [c :in rcodec/builtin] (c :name) c)))
  (rcodec/find-codec registry name))

(def component
  (system/component :cache/redis
    :doc "The cache store in redis: SET with an expiry, MGET, INCRBY,
    and a SCAN-and-delete `clear` scoped to the cache's own key prefix
    — never FLUSHDB, because the database is shared with whatever else
    the application keeps there. Values go through this plugin's own
    codec (:jdn by default), not the redis client's."
    :deps [:redis/client]
    :provides [:void/cache-store]
    :config {:key :cache-redis :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (merge defaults (or cfg0 {})))
      (def client (deps :redis/client))
      (def codec (pick-codec client (cfg :codec)))
      (log/info "cache redis store ready" :ns log-ns
                :codec (codec :name)
                :redis-prefix (get client :prefix ""))
      (make {:codec codec :scan-count (cfg :scan-count)}))
    :stop
    (fn stop [st] ((st :close)))
    :health
    (fn health [st]
      (merge {:status :up} ((st :stats))))))

(plugin/defplugin void/cache-redis
  :doc "The cache in redis: a :void/cache-store over void/redis — SET with an expiry, MGET, atomic INCRBY, and a clear that walks its own prefix rather than flushing a database it shares."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/cache ">=0.0.1" :void/redis ">=0.0.1"}
  :config-key :cache-redis
  :config-schema Config
  :config-defaults defaults
  :components [component])
