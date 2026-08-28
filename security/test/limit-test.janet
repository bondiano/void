(import ../test-support/paths)
(import void/security/limit :as limit)

(def store (limit/memory-store))
(defn- opts [&opt extra] (merge {:limit 3 :window 10 :now 1000} (or extra {})))

# -- the window ----------------------------------------------------------

(def results (seq [_ :range [0 5]] (limit/check! store "a" (opts))))
(assert (deep= [true true true false false] (tuple ;(map |($ :allowed) results)))
        "three through, the rest refused")
(assert (= 3 ((results 0) :limit)))
(assert (= 2 ((results 0) :remaining)))
(assert (zero? ((results 4) :remaining)))
(assert (= 10 ((results 4) :reset)) "and the reset says when the window turns over")

(assert ((limit/check! store "b" (opts)) :allowed) "another key has its own budget")

# the boundary: a fixed window would let three more through at once,
# which is the burst the weighted previous window exists to prevent
(assert (not ((limit/check! store "a" (opts {:now 1010})) :allowed))
        "at the start of the next window the previous one still counts in full")
(assert ((limit/check! store "a" (opts {:now 1019})) :allowed)
        "and by the end of it, it has faded out")

(def [index elapsed] (limit/window-of 1007 10))
(assert (= 100 index))
(assert (= 7 elapsed))

# -- headers -------------------------------------------------------------

(def allowed (limit/headers-for {:limit 3 :remaining 2 :reset 7 :allowed true}))
(assert (= "3" (allowed "ratelimit-limit")))
(assert (= "2" (allowed "ratelimit-remaining")))
(assert (= "7" (allowed "ratelimit-reset")))
(assert (nil? (allowed "retry-after")) "a request that went through is not told to wait")

(def refused (limit/headers-for {:limit 3 :remaining 0 :reset 7 :allowed false}))
(assert (= "7" (refused "retry-after"))
        "a refusal says how long to wait — a client that retries immediately makes it worse")

# -- a broken store ------------------------------------------------------

(def broken @{:name :broken
              :get (fn [_] (error "connection refused"))
              :incr (fn [_ _ _] (error "connection refused"))})

(def open-result (limit/check! broken "a" (opts)))
(assert (open-result :allowed)
        "fail open: an unreachable redis must not turn a rate limit into a site-wide outage")
(assert (string/find "connection refused" (open-result :error))
        "and the reason travels with the answer, so the caller logs it once")

(assert (not ((limit/check! broken "a" (opts {:on-error :deny})) :allowed))
        "an application that would rather fail closed says so")

# -- the memory store ----------------------------------------------------

(def s (limit/memory-store))
(assert (nil? ((s :get) "missing")))
(assert (= 1 ((s :incr) "k" 1 60)))
(assert (= 3 ((s :incr) "k" 2 60)))
(assert (= 3 ((s :get) "k")))
(assert ((s :delete) "k"))
(assert (nil? ((s :get) "k")))
((s :put) "gone" 5 -1)
(assert (nil? ((s :get) "gone")) "an expired entry is not there")
((s :incr) "p:1" 1 60)
((s :incr) "p:2" 1 60)
((s :incr) "q:1" 1 60)
(assert (= 2 ((s :clear) "p:")) "clear takes a prefix, so one limiter cannot wipe another's keys")
(assert (s :atomic-incr) "and it says its increment is its own — the property a shared store must have")

(print "limit-test ok")
