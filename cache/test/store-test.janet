(import ../test-support/paths)
(import void/cache/store :as store)

# -- the contract --------------------------------------------------------

(def minimal
  @{:name :test
    :entries @{}})

(defn- four-functions [state]
  {:name :test
   :get (fn [k] (get state k))
   :put (fn [k v ttl] (put state k v) v)
   :delete (fn [k] (if (nil? (get state k)) false (do (put state k nil) true)))
   :clear (fn [prefix]
            (var n 0)
            (each k (keys state)
              (when (string/has-prefix? (or prefix "") k)
                (put state k nil)
                (++ n)))
            n)})

(def state @{})
(def st (store/normalize (four-functions state)))

(each k [:get :put :delete :clear :get-many :put-many :has? :incr :stats :close]
  (assert (function? (st k)) (string/format "%q is filled in" k)))

(assert (= :test (st :name)))
(assert (= :janet (st :values)) "a store that says nothing keeps Janet values")

# -- the fallbacks do what the real ones would ---------------------------

((st :put) "a" 1 nil)
((st :put-many) [["b" 2] ["c" 3]] nil)
(assert (deep= @[1 2 3] ((st :get-many) ["a" "b" "c"])) "get-many over the loop of get")
(assert ((st :has?) "a"))
(assert (not ((st :has?) "nope")))
(assert (= 4 ((st :incr) "a" 3 nil)) "incr reads, adds and writes back")
(assert (= 3 ((st :incr) "fresh" 3 nil)) "a missing counter starts at zero")
(assert (not (store/atomic-incr? st))
        "and the fallback says it is not the atomic kind")
(assert (deep= {} ((st :stats))))

(def [ok err] (protect ((st :incr) "b" 1 nil)))
(assert ok "a number increments")
((st :put) "text" "hello" nil)
(def [nok nerr] (protect ((st :incr) "text" 1 nil)))
(assert (not nok) "a string does not")
(assert (string/find "not a number" nerr) "and the error says which key")

(assert (= 1 ((st :clear) "te")) "clear is scoped to a prefix")
(assert ((st :has?) "a") "and leaves what is not under it")

# -- a store that implements more keeps its own --------------------------

(def own (store/normalize (merge (four-functions @{})
                                 {:incr (fn [k d ttl] :mine)
                                  :values :bytes
                                  :stats (fn [] {:store :test})})))
(assert (= :mine ((own :incr) "k" 1 nil)) "an implemented key is not overwritten")
(assert (store/atomic-incr? own) "and it counts as atomic")
(assert (= :bytes (own :values)))
(assert (deep= {:store :test} ((own :stats))))

# -- validation ----------------------------------------------------------

(each [bad reason]
  [[{} "a store with no functions"]
   [{:get (fn [k]) :put (fn [k v t]) :delete (fn [k])} "a store with no :clear"]
   [{:get 1 :put (fn [k v t]) :delete (fn [k]) :clear (fn [p])} "a :get that is not a function"]
   [(merge (four-functions @{}) {:values :whatever}) "an unknown :values"]
   [(merge (four-functions @{}) {:name "test"}) "a :name that is not a keyword"]]
  (def [ok err] (protect (store/normalize bad)))
  (assert (not ok) (string reason " is refused"))
  (assert (string? err) "with a message naming the key"))

(printf "store-test: ok")
