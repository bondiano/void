(import ../test-support/paths)
(import void/core/log :as log)
(import void/cache/memory :as memory)
(import void/cache/state :as state)

(log/set-level! "void.cache" :error)

(defn- fresh [&opt opts]
  (def m (memory/make {:sweep-interval 0}))
  [m (state/make (memory/store m) (or opts {}))])

(defn- with-cache [c f] (with-dyns [state/cache-dyn c] (f)))

# -- without a cache -----------------------------------------------------

(def [nok nerr] (protect (state/active-cache)))
(assert (not nok) "the funnel says what is missing rather than nil-punning")
(assert (string/find ":cache/store" nerr) "and names the component")

# -- reads, writes and the prefix ----------------------------------------

(def [m c] (fresh {:prefix "app:" :ttl 60}))
(with-cache c
  (fn []
    (assert (deep= [false nil] (state/fetch "k")) "a cold key is a miss")
    (assert (nil? (state/get-value "k")))
    (assert (= :default (state/get-value "k" :default)))

    (state/put! "k" {:a 1})
    (assert (deep= [true {:a 1}] (state/fetch "k")))
    (assert (deep= {:a 1} (state/get-value "k")))
    (assert (state/has? "k"))
    (assert (deep= @["app:k"] (keys (m :entries)))
            "the prefix is what reaches the store, and it is the only thing above it")
    (assert (= "app:k" (state/full-key "k")))

    (assert (state/delete! "k"))
    (assert (not (state/delete! "k")))
    (assert (not (state/has? "k")))))

# -- ttl resolution ------------------------------------------------------

(def [tm tc] (fresh {:ttl 60}))
(with-cache tc
  (fn []
    (state/put! "default" 1)
    (assert (number? (get-in tm [:entries "default" :expires])) "the default ttl applies")

    (state/put! "forever" 1 :none)
    (assert (nil? (get-in tm [:entries "forever" :expires])) ":none means no expiry")

    (state/put! "not-stored" 1 0)
    (assert (not (state/has? "not-stored"))
            "a ttl of zero is how a call opts out of a default")

    (state/put! "nothing" nil)
    (assert (not (state/has? "nothing"))
            "and a nil is not a value a store can hold")))

# -- many at once --------------------------------------------------------

(def [mm mc] (fresh))
(with-cache mc
  (fn []
    (state/put-many! {"a" 1 "b" 2})
    (state/put-many! [["c" 3]])
    (assert (deep= @[1 2 3 nil] (state/get-many ["a" "b" "c" "gone"]))
            "get-many keeps the order and marks the holes")
    (assert (= 2 (state/forget "a" "b")) "forget counts what it dropped")))

# -- counters ------------------------------------------------------------

(def [im ic] (fresh))
(with-cache ic
  (fn []
    (assert (= 1 (state/incr! "hits")))
    (assert (= 6 (state/incr! "hits" 5)))
    (assert (= 6 (state/get-value "hits")))))

# -- remember ------------------------------------------------------------

(def [rm rc] (fresh {:ttl 60}))
(with-cache rc
  (fn []
    (var calls 0)
    (defn compute [] (++ calls) :value)
    (assert (= :value (state/remember "r" 10 compute)))
    (assert (= :value (state/remember "r" 10 compute)))
    (assert (= 1 calls) "the second call is the cached one")

    (assert (= :value (state/remember "r" {:ttl 10 :refresh true} compute)))
    (assert (= 2 calls) ":refresh recomputes without a window where the key is missing")

    (var nils 0)
    (defn absent [] (++ nils) nil)
    (state/remember "n" 10 absent)
    (state/remember "n" 10 absent)
    (assert (= 2 nils) "a nil is not cached on its own")

    (var nils2 0)
    (defn absent2 [] (++ nils2) nil)
    (assert (nil? (state/remember "n2" {:ttl 10 :cache-nil true} absent2)))
    (assert (nil? (state/remember "n2" {:ttl 10 :cache-nil true} absent2)))
    (assert (= 1 nils2) "unless it was asked for")
    (assert (deep= [true nil] (state/fetch "n2"))
            "and then fetch still tells a cached nil from a miss")

    (state/remember "zero" 0 compute)
    (assert (not (state/has? "zero")) "ttl 0 computes without storing")))

# -- a nil sentinel a store cannot carry ---------------------------------

(def bytes-store
  (state/make {:name :bytesy :values :bytes
               :get (fn [k] nil) :put (fn [k v t] v)
               :delete (fn [k] false) :clear (fn [p] 0)}))
(with-cache bytes-store
  (fn []
    (def [ok err] (protect (state/remember "n" {:cache-nil true} (fn [] nil))))
    (assert (not ok) "a store that cannot round-trip a keyword refuses to cache a nil")
    (assert (string/find ":jdn" err) "and says what to configure instead")))

# -- single flight -------------------------------------------------------

(def [sm sc] (fresh))
(with-cache sc
  (fn []
    (var calls 0)
    (def done (ev/chan 8))
    (def results @[])
    (each _ (range 5)
      (ev/go (fn []
               (array/push results
                           (state/remember "slow" 10
                                           (fn [] (++ calls) (ev/sleep 0.02) :once))))
             nil done))
    (each _ (range 5) (ev/take done))
    (assert (= 1 calls) "five fibers missing the same key compute it once")
    (assert (= 5 (length results)) "and all five get an answer")
    (assert (all |(= :once $) results))
    (assert (= 4 (get-in sc [:stats :flight-waits])))
    (assert (= 0 (state/in-flight)) "and nothing is left in flight")

    # the error is shared too, which is the half that matters: a herd
    # that all recompute after a failure is the herd this prevents
    (def failed (ev/chan 8))
    (var errs 0)
    (each _ (range 3)
      (ev/go (fn []
               (def [ok] (protect (state/remember "bad" 10
                                                  (fn [] (ev/sleep 0.01) (error "boom")))))
               (unless ok (++ errs)))
             nil failed))
    (each _ (range 3) (ev/take failed))
    (assert (= 3 errs) "the failure reaches every waiter")
    (assert (= 0 (state/in-flight)) "and the flight is cleared")))

# -- a flight its own leader re-enters -----------------------------------

(def [_ rc] (fresh {:ttl 60}))
(with-cache rc
  (fn []
    (assert (= 42 (state/remember "outer" 60
                                  (fn [] (+ 1 (state/remember "outer" 60 (fn [] 41))))))
            "a recursive remember on the same key computes instead of parking on its own flight")
    (assert (= 0 (state/in-flight)) "the flight is cleared, not poisoned")
    (assert (deep= [true 42] (state/fetch "outer")) "and the outer result is what stays")

    # after the recursion, strangers still share a flight — the dyn
    # cleanup did not turn single-flight off
    (var calls 0)
    (def done (ev/chan 4))
    (each _ (range 3)
      (ev/go (fn [] (state/remember "after" 10
                                    (fn [] (++ calls) (ev/sleep 0.01) :v)))
             nil done))
    (each _ (range 3) (ev/take done))
    (assert (= 1 calls) "single-flight still dedupes concurrent strangers")))

(def [_ nosf] (fresh {:single-flight false}))
(with-cache nosf
  (fn []
    (var calls 0)
    (def done (ev/chan 4))
    (each _ (range 3)
      (ev/go (fn [] (state/remember "slow" 10 (fn [] (++ calls) (ev/sleep 0.02) :v))) nil done))
    (each _ (range 3) (ev/take done))
    (assert (= 3 calls) "turned off, every fiber computes for itself")))

# -- a store that is broken ----------------------------------------------

(defn- broken [&opt opts]
  (state/make {:name :broken
               :get (fn [k] (error "the cache is down"))
               :put (fn [k v t] (error "the cache is down"))
               :delete (fn [k] (error "the cache is down"))
               :clear (fn [p] (error "the cache is down"))}
              (or opts {})))

(def down (broken))
(with-cache down
  (fn []
    (assert (deep= [false nil] (state/fetch "k")) "a failing read is a miss")
    (assert (= :computed (state/remember "k" 10 (fn [] :computed)))
            "so the application computes what it needed, exactly as on a cold cache")
    (assert (not (state/delete! "k")))
    (assert (= 0 (state/clear! :everything)))
    (assert (< 0 (get-in down [:stats :errors])) "every failure is counted")))

# -- clear! wants to know what it is clearing ----------------------------

(def [_ unprefixed] (fresh))
(with-cache unprefixed
  (fn []
    (def [ok err] (protect (state/clear!)))
    (assert (not ok) "with an empty prefix, clear! refuses rather than dropping every key the store holds")
    (assert (string/find ":everything" (string err)) "and says how to mean exactly that")
    (state/put! "k" 1)
    (assert (= 1 (state/clear! :everything)) "which then clears")))

(def [_ prefixed] (fresh {:prefix "app:"}))
(with-cache prefixed
  (fn []
    (state/put! "k" 1)
    (assert (= 1 (state/clear!)) "a prefixed cache clears without ceremony")))

(def strict (broken {:on-error :raise}))
(with-cache strict
  (fn []
    (def [ok err] (protect (state/fetch "k")))
    (assert (not ok) ":raise is there for the caller who would rather know")))

# -- a cache switched off ------------------------------------------------

(def [om oc] (fresh {:enabled false}))
(with-cache oc
  (fn []
    (state/put! "k" 1)
    (assert (deep= [false nil] (state/fetch "k")))
    (assert (not (state/has? "k")))
    (assert (= 0 (memory/entry-count om)) "nothing is written")
    (var calls 0)
    (state/remember "k" 10 (fn [] (++ calls) :v))
    (state/remember "k" 10 (fn [] (++ calls) :v))
    (assert (= 2 calls) "and every read-through recomputes")))

# -- stats ---------------------------------------------------------------

(def [_ stc] (fresh {:prefix "s:"}))
(with-cache stc
  (fn []
    (state/put! "a" 1)
    (state/fetch "a")
    (state/fetch "b")
    (def s (state/stats))
    (assert (= 1 (s :hits)))
    (assert (= 1 (s :misses)))
    (assert (= 0.5 (s :hit-rate)))
    (assert (= "s:" (s :prefix)))
    (assert (= :memory (s :store)) "the store's own numbers come along")
    (assert (= 1 (s :entries)))))

(printf "state-test: ok")
