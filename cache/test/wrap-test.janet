(import ../test-support/paths)
(import void/core/log :as log)
(import void/cache/memory :as memory)
(import void/cache/state :as state)
(import void/cache/wrap :as wrap)

(log/set-level! "void.cache" :error)

(def m (memory/make {:sweep-interval 0}))
(def c (state/make (memory/store m) {:ttl 60}))

(var calls 0)
(defn fetch-rates [currency] (++ calls) {:currency currency :rate 1.5})

(with-dyns [state/cache-dyn c]
  (def rates (wrap/wrap fetch-rates))

  (assert (deep= {:currency "usd" :rate 1.5} (rates "usd")))
  (assert (deep= {:currency "usd" :rate 1.5} (rates "usd")))
  (assert (= 1 calls) "the second call comes from the cache")

  (rates "eur")
  (assert (= 2 calls) "different arguments are a different key")

  (assert (index-of "fetch-rates[s3:usd]" (keys (m :entries)))
          "and the key is the function's name and its arguments, readable in a keyspace")

  # invalidating one call
  (assert (wrap/forget-call :fetch-rates "usd"))
  (rates "usd")
  (assert (= 3 calls) "which is what forget-call is for")
  (assert (= (wrap/key-for :fetch-rates "usd")
             "fetch-rates[s3:usd]")
          "key-for is the same key, for a caller who wants to invalidate by hand")

  # an anonymous function has no name to key on
  (def [ok err] (protect (wrap/wrap (fn [x] x))))
  (assert (not ok) "an anonymous function needs a :name")
  (assert (string/find "in every process" err) "and the error says why")

  (var named-calls 0)
  (def named (wrap/wrap (fn [x] (++ named-calls) x) {:name :identity}))
  (named 1) (named 1)
  (assert (= 1 named-calls) "given one, it works like any other")

  # :key, for arguments that are big or mostly irrelevant
  (var rendered 0)
  (def render (wrap/wrap (fn render [user id] (++ rendered) (string id))
                         {:name :page :key (fn [user id] id)}))
  (assert (= "7" (render {:name "ann" :roles [:admin]} 7)))
  (assert (= "7" (render {:name "bob" :roles []} 7)))
  (assert (= 1 rendered) "only the part of the call the key names matters")
  (assert (index-of "page:7" (keys (m :entries))) "and the key says so")

  # :when, for the calls that should not be cached at all
  (var raw 0)
  (def small (wrap/wrap (fn small [x] (++ raw) x) {:when (fn [x] (< x 10))}))
  (small 1) (small 1)
  (small 50) (small 50)
  (assert (= 3 raw) "one cached call and two uncached ones")

  # ttl, and nil results
  (var slow 0)
  (def brief (wrap/wrap (fn brief [] (++ slow) :v) {:ttl 0.05}))
  (brief) (brief)
  (assert (= 1 slow))
  (ev/sleep 0.07)
  (brief)
  (assert (= 2 slow) "the ttl is the wrapper's, not the cache's default")

  (var absent 0)
  (def missing (wrap/wrap (fn missing [] (++ absent) nil) {:cache-nil true}))
  (missing) (missing)
  (assert (= 1 absent) "a cached nil is a cached answer")

  # single-flight comes along, because wrap is remember
  (var concurrent 0)
  (def expensive (wrap/wrap (fn expensive [] (++ concurrent) (ev/sleep 0.02) :once)))
  (def done (ev/chan 8))
  (each _ (range 4) (ev/go (fn [] (expensive)) nil done))
  (each _ (range 4) (ev/take done))
  (assert (= 1 concurrent) "four fibers, one computation"))

(printf "wrap-test: ok")
