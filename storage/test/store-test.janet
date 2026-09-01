# The contract, and what it fills in. A store is five functions plus
# two declarations; everything else `normalize` provides, so that a
# working backend never has to write a fallback it did not want.

(import ../test-support/paths)
(import void/storage/store :as store)

(def- bytes-of @{})

(defn- minimal
  "The smallest thing that is a store."
  []
  @{:name :test
    :put! (fn [k v _] (put bytes-of k v) {:key k :size (length v)})
    :get (fn [k] (get bytes-of k))
    :stream (fn [k] (when-let [b (get bytes-of k)] [b]))
    :delete! (fn [k] (if (get bytes-of k) (do (put bytes-of k nil) true) false))
    :url (fn [k _] (string "/files/" k))})

# -- the contract --------------------------------------------------------

(def st (store/normalize (minimal)))

(each k [:put! :get :stream :delete! :url :stat :close]
  (assert (function? (st k)) (string/format "%q is filled in" k)))

(assert (= :test (st :name)))
(assert (not (store/shared? st))
        "a store that does not say whether replicas share it is taken to be per-process")

# the :stat fallback is honest about what it costs — it reads the object
((st :put!) "a.txt" "hello" {})
(assert (= 5 (((st :stat) "a.txt") :size)) "the fallback :stat measures what it read")
(assert (nil? ((st :stat) "nothing.txt")) "and answers nil for what is not there")

# a store that knows better keeps its own
(def own (store/normalize (merge (minimal) {:stat (fn [k] {:key k :size 42})})))
(assert (= 42 (((own :stat) "a.txt") :size)) "a store's own :stat is not overwritten")

(assert (nil? ((st :close))) "the :close fallback does nothing, quietly")

# -- validation ----------------------------------------------------------

(defn- without [k]
  (def m (minimal))
  (put m k nil)
  m)

(each [bad reason]
  [[{} "a store with no functions"]
   [(without :put!) "a store with no :put!"]
   [(without :url) "a store with no :url"]
   [(merge (minimal) {:stream "not a function"}) "a store whose :stream is not a function"]
   [(merge (minimal) {:stat 7}) "a store whose optional :stat is not a function"]
   [(merge (minimal) {:name "s3"}) "a store whose :name is not a keyword"]
   ["not a dictionary" "something that is not a dictionary"]]
  (def [ok err] (protect (store/normalize bad)))
  (assert (not ok) (string reason " is refused"))
  (assert (string? err) "with a message naming the key"))

# -- what a store declares about replicas --------------------------------

(assert (store/shared? (store/normalize (merge (minimal) {:shared? true})))
        "a store that says it is shared is believed")
(assert (not (store/shared? (store/normalize (merge (minimal) {:shared? false}))))
        "and so is one that says it is not")

(printf "store-test: ok")
