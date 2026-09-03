### void/cache — the cache plugin.
###
### Two interfaces and one funnel. `:void/cache-store` is a backend —
### four functions over strings and values (./store); `:void/cache` is
### what an application depends on, and it is the layer that turns a
### backend into a cache: a key prefix, a default TTL, single-flight,
### and the decision that a broken store degrades to a miss rather
### than to a 500 (./state). What lives where:
###
###   ./key      keys, deterministically — the same call, the same key,
###              in every process
###   ./store    the :void/cache-store contract and its fallbacks
###   ./memory   the in-process store: TTL and an exact LRU
###   ./state    the active cache, the funnel, single-flight
###   ./wrap     (cache/wrap f) — memoize through the cache
###
### Two components. `:cache/memory` is the store this plugin ships and
### the default backend; `:cache/store` is the cache over whichever
### `:void/cache-store` is active. Adding void/cache-redis puts a
### second component on that interface, which is the ambiguity the
### kernel refuses to resolve on its own — the application names the
### one it means, exactly as it does with two database drivers:
###
###     (void/run! {:plugins [:void/cache :void/cache-redis ...]})
###     # config/prod.janet
###     {:void/cache-store {:impl :cache/redis}
###      :cache {:prefix "myapp:" :ttl 600}}
###
### Applications import `void/cache` and nothing below it:
###
###     (import void/cache :as cache)
###     (cache/remember "rates" 300 fetch-rates)
###     (def rates (cache/wrap fetch-rates {:ttl 300}))
###     (cache/forget "rates")
###
### Response caching on routes marked `:void.cache/response` is the
### companion plugin void/cache-http (./http) — the one piece that
### needs void/http, kept separate so a CLI or a worker never drags the
### HTTP kernel in, exactly as void/db-http is to void/db.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./key :as key)
(import ./memory :as memory)
(import ./state :as state)
(import ./store :as store)
(import ./wrap :as wrap)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.cache")

# -- the interfaces ------------------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/cache
   :doc "A cache: the :cache/store component's value — a normalized store under a key prefix, with a default TTL, single-flight and an error policy. Depend on the interface rather than the key to let a test stand a stub in its place."
   :methods {:store "the :void/cache-store backend (see void/cache/store)"
             :prefix "the string every key is prefixed with"
             :ttl "the default time to live, in seconds (:none for no expiry)"}})

(plugin/contribute! :void.core/interface
  {:name :void/cache-store
   :doc "A cache backend: {:get :put :delete :clear} plus the optional :get-many/:put-many, :has?, :incr, :stats and :close keys (see void/cache/store). A store component declares :provides [:void/cache-store]; {:void/cache-store {:impl <key>}} picks between several."
   :methods {:get "(fn [key] value-or-nil)"
             :put "(fn [key value ttl])"
             :delete "(fn [key] deleted?)"
             :clear "(fn [key-prefix] n)"}})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:cache] config slice."
  {:enabled [:optional :boolean]
   # what makes one store serve several applications — and one
   # developer's laptop several checkouts — without them reading each
   # other's entries. It is also what `clear` is scoped to
   :prefix [:optional :string]
   :ttl [:optional [:or [:number {:min 0}] [:enum :none]]]
   :single-flight [:optional :boolean]
   :on-error [:optional [:enum :degrade :raise]]
   :memory [:optional {:max-entries [:optional [:int {:min 1}]]
                       :sweep-interval [:optional [:number {:min 0}]]}]})

(def defaults
  ``Defaults of the [:cache] slice. The one worth arguing about is the
  five-minute TTL: a cache with no expiry is a memory leak with a good
  reputation, and the entry that is never invalidated is the entry
  that serves last week's price. `:ttl :none` is there for the caller
  who means it.``
  {:enabled true
   :prefix "cache:"
   :ttl 300
   :single-flight true
   :on-error :degrade
   :memory {:max-entries 1000 :sweep-interval 60}})

(defn- slice [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (put cfg :memory (merge (defaults :memory) (get (or cfg0 {}) :memory {})))
  cfg)

# -- public surface (re-exports) -----------------------------------------

(def Store "See store/normalize — the :void/cache-store contract." store/normalize)
(def store-atomic-incr? "See store/atomic-incr?." store/atomic-incr?)

(def canonical-key "See key/canonical — a deterministic rendering of a value." key/canonical)
(def store-key "See key/cache-key — a key as the store sees it (before the prefix)." key/cache-key)

(def memory-store "See memory/store — an in-process TTL+LRU store." memory/store)
(def make-memory "See memory/make — the table behind one." memory/make)

(def cache-dyn "See state/cache-dyn — the cache override." state/cache-dyn)
(def active-cache "See state/active-cache." state/active-cache)
(def active-store "See state/active-store — the backend behind it." state/active-store)
(def make-cache "See state/make — a cache value without a bootstrap." state/make)
(def full-key "See state/full-key — a key with the cache prefix on it." state/full-key)
(def enabled? "See state/enabled?." state/enabled?)

(def fetch "See state/fetch — [found? value], the reader that tells a cached nil from a miss." state/fetch)
(def has? "See state/has?." state/has?)
(def get-many "See state/get-many — several keys, one round trip." state/get-many)
(def put! "See state/put! — store a value." state/put!)
(def put-many! "See state/put-many!." state/put-many!)
(def delete! "See state/delete!." state/delete!)
(def forget "See state/forget — drop keys." state/forget)
(def clear! "See state/clear! — drop everything under the cache prefix." state/clear!)
(def incr! "See state/incr! — add to a counter." state/incr!)
(def remember "See state/remember — read-through: the cached value, or the thunk's." state/remember)
(def in-flight "See state/in-flight — keys being computed right now." state/in-flight)
(def stats "See state/stats — hits, misses, hit rate, store failures." state/stats)

(def wrap "See wrap/wrap — memoize a function through the cache." wrap/wrap)
(def key-for "See wrap/key-for — the key a wrapped call is stored under." wrap/key-for)
(def forget-call "See wrap/forget-call — drop one wrapped call's result." wrap/forget-call)

# -- the memory store component ------------------------------------------

(def memory-component
  (system/component :cache/memory
    :doc "The in-process cache store: a table of entries with TTLs, an
    exact LRU over a recency list of keys, and a sweeper fiber that
    drops what expired without being read again. The default backend,
    and the one an application starts with — swapping it for redis is
    a config line once void/cache-redis is in the composition."
    :provides [:void/cache-store]
    :config {:key :cache :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def m (memory/make (cfg :memory)))
      (memory/start-sweeper! m)
      (log/info "cache memory store ready" :ns log-ns
                :max-entries (get-in cfg [:memory :max-entries])
                :sweep-interval (get-in cfg [:memory :sweep-interval]))
      (memory/store m))
    :stop
    (fn stop [st]
      ((st :close)))
    :health
    (fn health [st]
      (merge {:status :up} ((st :stats))))))

# -- the cache component -------------------------------------------------

(def cache-component
  (system/component :cache/store
    :doc "The cache over the active :void/cache-store: the key prefix
    that keeps applications out of each other's entries, the default
    TTL, single-flight so that a cold key is computed once however
    many fibers want it, and the policy that a failing store degrades
    to a miss instead of taking the request down with it."
    :deps [:void/cache-store]
    :provides [:void/cache]
    :config {:key :cache :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (slice cfg0))
      (def st (deps :void/cache-store))
      (def value (state/make st cfg))
      (set state/current-cache value)
      (log/info "cache ready" :ns log-ns
                :store (get-in value [:store :name])
                :prefix (value :prefix)
                :ttl (get cfg :ttl)
                :single-flight (value :single-flight)
                :on-error (value :on-error)
                :enabled (not= false (cfg :enabled)))
      value)
    :stop
    (fn stop [_]
      (set state/current-cache nil))
    :health
    (fn health [c]
      (merge {:status :up} (with-dyns [state/cache-dyn c] (state/stats))))))

(plugin/contribute! :void.core/store
  {:name :void/cache-store
   :what "the cache"
   :needs [:cache/store]
   :doc "The cache backend this composition resolved — and therefore what `cache/forget` reaches"
   :ask (fn ask-cache [boot]
          (when-let [c (get-in boot [:system :instances :cache/store])]
            (def st (c :store))
            {:store (get st :name :anonymous)
             :shared? (store/shared? st)
             # the sharpest form of the bug this answers: an
             # invalidation that clears one replica and leaves the
             # stale answer on the others
             :replacement "compose void/cache-redis and set {:void/cache-store {:impl :cache/redis}} — otherwise cache/forget clears one replica's entries and the rest keep serving the stale value"}))})

# -- CLI -----------------------------------------------------------------

(defn- with-cache [c f]
  (with-dyns [state/cache-dyn c] (f)))

(plugin/contribute! :void.core/cli
  {:name :cache/stats
   :read-only? true
   :doc "Show what the cache has been doing: void cache stats"
   :needs [:cache/store]
   # :needs instances come first, then the string arguments
   :fn (fn cli-stats [c & args]
         (unless (empty? args)
           (errorf "void cache stats takes no arguments (got %q)" (string/join args " ")))
         (def s (with-cache c state/stats))
         (printf "store       %q" (get-in c [:store :name]))
         (printf "prefix      %q" (c :prefix))
         (printf "ttl         %q" (get c :ttl))
         (printf "enabled     %q" (s :enabled))
         (printf "hits        %d" (s :hits))
         (printf "misses      %d" (s :misses))
         (printf "hit rate    %.1f%%" (* 100 (s :hit-rate)))
         (printf "writes      %d" (s :puts))
         (printf "deletes     %d" (s :deletes))
         (printf "store fails %d" (s :errors))
         (printf "in flight   %d" (s :in-flight))
         (when-let [n (s :entries)]
           (printf "entries     %d of %d" n (get s :max-entries 0))))})

(plugin/contribute! :void.core/cli
  {:name :cache/get
   :read-only? true
   :doc "Read one key: void cache get KEY"
   :needs [:cache/store]
   :fn (fn cli-get [c & args]
         (unless (= 1 (length args))
           (error "usage: void cache get KEY"))
         (def k (first args))
         (def [found v] (with-cache c (fn [] (state/fetch k))))
         (if found
           (printf "%s = %q" (with-cache c (fn [] (state/full-key k))) v)
           (printf "%s is not cached" (with-cache c (fn [] (state/full-key k))))))})

(plugin/contribute! :void.core/cli
  {:name :cache/forget
   :read-only? false
   :doc "Drop one key: void cache forget KEY"
   :needs [:cache/store]
   :fn (fn cli-forget [c & args]
         (unless (= 1 (length args))
           (error "usage: void cache forget KEY"))
         (def k (first args))
         (if (with-cache c (fn [] (state/delete! k)))
           (printf "dropped %s" (with-cache c (fn [] (state/full-key k))))
           (printf "%s was not cached" (with-cache c (fn [] (state/full-key k))))))})

(plugin/contribute! :void.core/cli
  {:name :cache/clear
   :read-only? false
   :doc "Drop everything under the cache prefix: void cache clear (--everything when the prefix is empty and every key is meant)"
   :needs [:cache/store]
   :fn (fn cli-clear [c & args]
         (def everything (deep= args @["--everything"]))
         (unless (or (empty? args) everything)
           (errorf "void cache clear takes no arguments but --everything (got %q)" (string/join args " ")))
         (def n (with-cache c (fn [] (state/clear! (when everything :everything)))))
         (printf "dropped %d %s under %q"
                 n (if (= 1 n) "entry" "entries") (c :prefix)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/cache
  :doc "The cache: the :void/cache-store contract, an in-process TTL+LRU store, read-through (remember) and memoization (wrap) with single-flight, and a store failure that degrades to a miss rather than to a 500."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :cache
  :config-schema Config
  :config-defaults defaults
  :components [memory-component cache-component])

# -- names that shadow the core ------------------------------------------
#
# Last, and deliberately: `get` is a core function, and a module that
# shadows it before its own code is written is a module that cannot use
# it. Everything above is defined; from here nothing is.

(def get "See state/get-value — the cached value, or the default." state/get-value)
