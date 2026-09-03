### void/security/limit — rate limiting over the cache-store contract.
###
### A limiter needs "key -> counter with a TTL and an increment". That
### is exactly `:void/cache-store` (wave 2), which already has a memory
### implementation, a redis implementation and an honest answer to
### whether its increment is atomic. Defining a second contract would
### have produced the same four functions with different names, so
### there is not one: `[:security :rate :store] :cache` uses the
### composition's store, and `:memory` uses the one below, which is the
### same shape and lets this package work alone.
###
### **The algorithm is a sliding window over two counters.** A fixed
### window lets twice the limit through across a boundary (all of it at
### 0:59, all of it again at 1:00); a true sliding log costs a
### timestamp per request. The standard middle is to weight the
### previous window by how much of it is still in view:
###
###     count = current + previous × (window − elapsed) / window
###
### One read and one increment per request, no burst at the boundary,
### and an error of a few percent against an exact log — which is the
### right trade for a limiter whose thresholds are round numbers
### somebody guessed anyway.
###
### **A broken store fails open.** If redis is unreachable the limiter
### allows the request and says so in the result (`:error`), because a
### limiter that turns an infrastructure outage into a site-wide 429 is
### a worse outage than the one it was protecting against. An
### application that would rather fail closed says
### `[:security :rate :on-error :deny]` — the same choice `void/cache`
### offers, made the same way.

(def defaults
  "Defaults of the [:security :rate] slice."
  {:enabled true
   :store :memory
   :limit 60
   :window 60
   :key :ip
   :on-error :allow
   :prefix "void:rate:"
   :status 429
   :message "too many requests"})

(defn memory-store
  ``An in-process store with the `:void/cache-store` shape — enough of
  it for a counter. Per process, and that is the whole of its
  arithmetic: N processes counting separately let N times the
  configured limit through, so a fleet's "60 per minute" is 180 across
  three replicas. `[:deploy :shape] :fleet` refuses it at start
 rather than let the number be discovered from a graph.``
  [&opt opts]
  (default opts {})
  (def entries @{})
  (defn now [] (os/time))
  (defn sweep []
    (def t (now))
    (each k (seq [[k v] :pairs entries :when (< (v :expires) t)] k)
      (put entries k nil))
    nil)
  (var writes 0)
  @{:name :memory
    :shared? false
    :entries entries
    :get (fn store-get [key]
           (when-let [e (get entries key)]
             (if (< (e :expires) (now)) (do (put entries key nil) nil) (e :value))))
    :put (fn store-put [key value ttl]
           (put entries key @{:value value :expires (+ (now) (or ttl 60))})
           value)
    :incr (fn store-incr [key delta ttl]
            (++ writes)
            (when (zero? (% writes (get opts :sweep-every 512))) (sweep))
            (def e (get entries key))
            (def live (and e (>= (e :expires) (now))))
            (def next (+ (if live (e :value) 0) delta))
            (put entries key @{:value next :expires (if live (e :expires) (+ (now) (or ttl 60)))})
            next)
    :delete (fn store-delete [key] (put entries key nil) true)
    :clear (fn store-clear [prefix]
             (def hit (seq [k :keys entries :when (string/has-prefix? prefix k)] k))
             (each k hit (put entries k nil))
             (length hit))
    :sweep sweep
    :atomic-incr true})

(defn window-of
  "The window index and how far into it `now` is."
  [now window]
  (def index (math/floor (/ now window)))
  [index (- now (* index window))])

(defn check!
  ``Count one request against `key` and answer whether it may proceed:

      {:allowed true :limit 60 :remaining 41 :reset 37 :count 19.4}

  `opts`: :limit :window :now :prefix :on-error.``
  [store key opts]
  (def limit (get opts :limit (defaults :limit)))
  (def window (get opts :window (defaults :window)))
  (def now (get opts :now (os/time)))
  (def prefix (get opts :prefix (defaults :prefix)))
  (def [index elapsed] (window-of now window))
  (def current-key (string prefix key ":" index))
  (def previous-key (string prefix key ":" (dec index)))
  (def [ok result]
    (protect
      (do
        (def previous (or ((store :get) previous-key) 0))
        # two windows of TTL: the previous one has to survive long
        # enough to be weighted
        (def current ((store :incr) current-key 1 (* 2 window)))
        [previous current])))
  (if-not ok
    # the store is broken; the policy decides, and the reason travels
    # with the answer so the caller can log it once rather than guess
    {:allowed (not= :deny (get opts :on-error (defaults :on-error)))
     :limit limit
     :remaining 0
     :reset window
     :count 0
     :error (string result)}
    (let [[previous current] result
          weight (/ (- window elapsed) window)
          counted (+ current (* previous weight))]
      {:allowed (<= counted limit)
       :limit limit
       :remaining (max 0 (math/floor (- limit counted)))
       :reset (math/ceil (- window elapsed))
       :count counted})))

(defn headers-for
  ``The IETF draft `RateLimit-*` headers for a result, plus
  `Retry-After` when it is a refusal. A client that is told how long
  to wait is a client that stops making it worse.``
  [result]
  (def out @{"ratelimit-limit" (string (result :limit))
             "ratelimit-remaining" (string (result :remaining))
             "ratelimit-reset" (string (result :reset))})
  (unless (result :allowed)
    (put out "retry-after" (string (result :reset))))
  out)
