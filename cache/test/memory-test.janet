(import ../test-support/paths)
(import void/core/log :as log)
(import void/cache/memory :as memory)
(import void/cache/store :as store)

(log/set-level! "void.cache" :error)

# -- TTL -----------------------------------------------------------------

(def m (memory/make {:sweep-interval 0}))

(memory/put! m "forever" :v nil)
(memory/put! m "brief" :v 0.05)
(assert (= :v (memory/lookup m "brief")))
(ev/sleep 0.07)
(assert (nil? (memory/lookup m "brief")) "an expired entry reads as absent")
(assert (= 0 (length (filter |(= "brief" $) (keys (m :entries)))))
        "and is dropped by the read that found it expired")
(assert (= :v (memory/lookup m "forever")) "no ttl means no expiry")

(assert (not (memory/present? m "brief")))
(assert (memory/present? m "forever"))
(def before (get-in m [:stats :hits]))
(memory/present? m "forever")
(assert (= before (get-in m [:stats :hits]))
        "asking whether a key is there is not using it")

# -- LRU, and that it is exact -------------------------------------------

(def lru (memory/make {:max-entries 3 :sweep-interval 0}))
(each k ["a" "b" "c"] (memory/put! lru k k nil))
(memory/lookup lru "a")   # a is now the most recently used
(memory/put! lru "d" "d" nil)

(assert (nil? (memory/lookup lru "b")) "the least recently used entry went")
(assert (= "a" (memory/lookup lru "a"))
        "and it was chosen by use, not by write order — a was written first and read last")
(assert (= "c" (memory/lookup lru "c")))
(assert (= "d" (memory/lookup lru "d")))
(assert (= 3 (memory/entry-count lru)) "the cap holds")
(assert (= 1 (get-in lru [:stats :evictions])))

(def big (memory/make {:max-entries 2 :sweep-interval 0}))
(each i (range 100) (memory/put! big (string i) i nil))
(assert (= 2 (memory/entry-count big)) "a hundred writes into a cache of two stay two")

# -- overwriting ---------------------------------------------------------

(def o (memory/make {:sweep-interval 0}))
(memory/put! o "k" 1 nil)
(memory/put! o "k" 2 nil)
(assert (= 2 (memory/lookup o "k")))
(assert (= 1 (memory/entry-count o)) "an overwrite is not a second entry")
(memory/put! o "k" 3 0.05)
(ev/sleep 0.07)
(assert (nil? (memory/lookup o "k")) "and it carries the new ttl")

# -- deleting and clearing -----------------------------------------------

(def c (memory/make {:sweep-interval 0}))
(each k ["p:1" "p:2" "q:1"] (memory/put! c k k nil))
(assert (memory/delete! c "q:1"))
(assert (not (memory/delete! c "q:1")) "deleting twice is not an error, just false")
(assert (= 2 (memory/clear! c "p:")) "clear takes a prefix")
(assert (= 0 (memory/entry-count c)))

(def all (memory/make {:sweep-interval 0}))
(each k ["a" "b"] (memory/put! all k k nil))
(assert (= 2 (memory/clear! all)) "and no prefix means everything")
(assert (nil? (all :head)) "the recency list is emptied with the entries")

# -- the recency list stays consistent -----------------------------------

(def lst (memory/make {:max-entries 4 :sweep-interval 0}))
(each k ["a" "b" "c" "d"] (memory/put! lst k k nil))
(memory/lookup lst "b")
(memory/delete! lst "c")
(memory/put! lst "e" "e" nil)
(assert (= "e" (lst :head)) "the newest write is the head")
(each k ["a" "b" "d" "e"]
  (assert (= k (memory/lookup lst k)) (string k " survived the shuffling")))
(assert (nil? (memory/lookup lst "c")))

# a cache that prints is a cache you can debug: the recency list is
# built out of keys precisely so this cannot become a cycle
(assert (string? (string/format "%q" lst)) "the whole store renders")

# -- sweeping ------------------------------------------------------------

(def sw (memory/make {:sweep-interval 0}))
(each i (range 5) (memory/put! sw (string i) i 0.03))
(memory/put! sw "keep" :keep nil)
(ev/sleep 0.05)
(assert (= 6 (memory/entry-count sw)) "nothing expires by itself without a sweep")
(assert (= 5 (memory/sweep! sw)) "the sweep drops what expired")
(assert (= 1 (memory/entry-count sw)))
(assert (= :keep (memory/lookup sw "keep")))

(def bg (memory/make {:sweep-interval 0.03}))
(memory/start-sweeper! bg)
(memory/put! bg "brief" 1 0.01)
(ev/sleep 0.1)
(assert (= 0 (memory/entry-count bg)) "the sweeper fiber does it without being asked")
(memory/stop-sweeper! bg)
(ev/sleep 0.05)
(assert (not (bg :sweeping)))

# a store stopped in the same turn it was started — what a short-lived
# CLI command does — must not leave a cancelled fiber behind
(def quick (memory/make {:sweep-interval 30}))
(memory/start-sweeper! quick)
(memory/stop-sweeper! quick)
(ev/sleep 0.02)
(assert (not (quick :sweeping)) "and stopping before it ever ran is quiet")

(def off (memory/make {:sweep-interval 0}))
(memory/start-sweeper! off)
(assert (not (off :sweeping)) "interval 0 means no sweeper at all")

# -- the store view ------------------------------------------------------

(def sm (memory/make {:sweep-interval 0}))
(def st (store/normalize (memory/store sm)))
((st :put) "k" {:a 1} nil)
(assert (deep= {:a 1} ((st :get) "k")))
(assert ((st :has?) "k"))
(assert (= :memory (st :name)))
(assert (= :janet (st :values)))
(assert (= sm (get (memory/store sm) :memory)) "the table stays reachable for health and the REPL")

# the asymmetry the store contract documents: an in-process cache hands
# back the value it was given, not a copy of it
(def shared @{:count 1})
((st :put) "shared" shared nil)
(put ((st :get) "shared") :count 2)
(assert (= 2 (get ((st :get) "shared") :count))
        "a mutable value cached in-process is shared with the caller — freeze what you cache")

(def s ((st :stats)))
(assert (= :memory (s :store)))
(assert (= 2 (s :entries)) "the key and the shared table")
(assert (number? (s :hits)))

((st :close))
(assert (= 0 (memory/entry-count sm)) "closing takes the entries with it")

(printf "memory-test: ok")
