(import ../test-support/paths)
(import ../test-support/redis :as server)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/redis/codec :as rcodec)
(import void/redis/state :as redis)
(import void/cache/redis :as backend)
(import void/cache/state :as state)
(import void/cache/store :as store)
(require "void/cache/init")
(require "void/redis/init")

(log/set-level! "void" :error)

# -- what can be checked without a server --------------------------------

(def report
  (plugin/dry-run {:plugins [:void/redis :void/cache :void/cache-redis]
                   :profile :test
                   :config {:env @{}
                            :cli {:log {:level :error}
                                  :void/cache-store {:impl :cache/redis}}}}))
(assert (report :ok) "the three plugins compose")
(assert (index-of :cache/redis (report :components)))

(def [ok err]
  (protect (plugin/dry-run {:plugins [:void/redis :void/cache :void/cache-redis]
                            :profile :test
                            :config {:env @{} :cli {:log {:level :error}}}})))
(assert (not ok) "two stores on one interface without a choice is a boot error")
(assert (and (string/find ":cache/memory" err) (string/find ":cache/redis" err))
        "listing the candidates, the way two database drivers do")
(assert (string/find ":impl" err) "and the config key that resolves it")

(def raw-store (backend/make {:codec rcodec/raw}))
(assert (= :bytes (raw-store :values))
        "a :raw codec cannot carry a keyword, and the store says so")
(assert (= :janet ((backend/make {:codec rcodec/jdn}) :values)))

# -- the rest needs a server ---------------------------------------------

(if-not (server/available?)
  (server/skip "redis-test")
  (server/with-client*
    "store"
    (fn [client]
      (def st (store/normalize (backend/make {:codec rcodec/jdn})))
      (def c (state/make st {:prefix "app:" :ttl 60}))

      (with-dyns [state/cache-dyn c]
        # values survive the round trip, structure and all
        (state/put! "k" {:a [1 2 :three] :b "text"})
        (assert (deep= {:a [1 2 :three] :b "text"} (state/get-value "k"))
                "jdn brings a table back a table, keywords included")
        (assert (state/has? "k"))
        (assert (deep= [true {:a [1 2 :three] :b "text"}] (state/fetch "k")))

        # the expiry is redis', on redis' clock
        (def key-on-server (string (client :prefix) "app:k"))
        (def pttl (redis/call ["PTTL" key-on-server]))
        (assert (and (> pttl 55000) (<= pttl 60000)) "the ttl reached the server")

        (state/put! "forever" 1 :none)
        (assert (= -1 (redis/call ["PTTL" (string (client :prefix) "app:forever")]))
                ":none means no expiry at all")

        (state/put! "brief" 1 0.05)
        (ev/sleep 0.1)
        (assert (not (state/has? "brief")) "and a short one is gone when it says")

        # several at once
        (state/put-many! {"m1" 1 "m2" 2})
        (assert (deep= @[1 2 nil] (state/get-many ["m1" "m2" "gone"]))
                "MGET keeps the order and marks the holes")

        # the counter is redis', which is what makes it exact
        (assert (store/atomic-incr? st) "the store implements :incr itself")
        (assert (= 1 (state/incr! "hits" 1 60)))
        (assert (= 6 (state/incr! "hits" 5 60)))
        (def hit-ttl (redis/call ["PTTL" (string (client :prefix) "app:hits")]))
        (assert (and (> hit-ttl 0) (<= hit-ttl 60000))
                "the expiry is set when the counter is created")

        # a cached nil round-trips through jdn
        (assert (nil? (state/remember "absent" {:ttl 10 :cache-nil true} (fn [] nil))))
        (assert (deep= [true nil] (state/fetch "absent")))

        # and, unlike the in-process store, what comes back is a copy
        (def shared @{:count 1})
        (state/put! "shared" shared)
        (put (state/get-value "shared") :count 2)
        (assert (= 1 (get (state/get-value "shared") :count))
                "a value read out of redis was decoded, so mutating it changes nothing")

        # clear walks the cache's own prefix and nothing else
        (redis/call ["SET" (string (client :prefix) "not-the-cache") "keep"])
        (def dropped (state/clear!))
        (assert (pos? dropped))
        (assert (not (state/has? "k")) "the cache is empty")
        (assert (= "keep" (string (redis/call ["GET" (string (client :prefix) "not-the-cache")])))
                "and the key that was not the cache's is still there — clear never flushes")

        # a prefix with a glob character in it is a prefix, not a pattern
        (def globby (state/make st {:prefix "we[i]rd:"}))
        (with-dyns [state/cache-dyn globby]
          (state/put! "x" 1)
          (assert (= 1 (state/clear!)) "and it clears exactly its own"))

        (redis/call ["DEL" (string (client :prefix) "not-the-cache")])

        (printf "redis-test: ok")))))
