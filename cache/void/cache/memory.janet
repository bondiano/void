### void/cache/memory — the in-process store: TTL and an exact LRU.
###
### A table of entries plus a recency list, which is the textbook answer;
### the one decision worth stating is how the list is built. The usual
### intrusive doubly-linked list stores *the neighbouring entries* in each
### entry, and a cache built that way is a cycle: `pp` on the component
### walks it forever, and "all runtime state lives inside the system value
### itself, fully inspectable from the REPL" stops being true the moment
### someone tries it. So the links here are **keys**, not entries: two
### extra hash lookups per touch, no cycles anywhere, and the whole store
### prints.
###
### Eviction is exact LRU, not an approximation: the entry evicted is
### the one least recently *used*, reads included, because a cache
### where a hot key that is never rewritten gets evicted is a cache
### that behaves worst exactly where it matters most.
###
### Expiry happens twice, and it needs to. Lazily, on read, because
### that is the only moment where correctness is at stake; and in a
### sweeper fiber, because a value nobody reads again would otherwise
### sit in the heap until LRU pressure pushed it out, which on a cache
### that never fills is never. The sweeper is one fiber per store,
### asleep between passes, and `[:cache :memory :sweep-interval] 0`
### turns it off for a process that would rather not have one.
###
### What this store deliberately does not have is a byte cap. "How
### many bytes is this Janet value" has no cheap answer and no exact
### one — a table shared with the application is not the cache's
### memory to count — so the cap is entries, which is a number the
### application can reason about, and the docstring says so instead of
### a :max-bytes key that would have to lie.

(import void/core/log :as log)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.cache.memory")

(def defaults
  "Defaults of the [:cache :memory] slice."
  {:max-entries 1000
   :sweep-interval 60})

(defn- now [] (os/clock :monotonic))

(defn- bump [m k]
  (def s (m :stats))
  (put s k (inc (s k))))

# -- the recency list (over keys, never over entries) --------------------

(defn- unlink! [m k e]
  (def entries (m :entries))
  (def p (e :prev))
  (def n (e :next))
  (if p (put-in entries [p :next] n) (put m :head n))
  (if n (put-in entries [n :prev] p) (put m :tail p))
  (put e :prev nil)
  (put e :next nil))

(defn- push-front! [m k e]
  (def h (m :head))
  (put e :prev nil)
  (put e :next h)
  (when h (put-in m [:entries h :prev] k))
  (put m :head k)
  (unless (m :tail) (put m :tail k)))

(defn- touch! [m k e]
  (unless (= k (m :head))
    (unlink! m k e)
    (push-front! m k e)))

(defn- drop! [m k e]
  (unlink! m k e)
  (put (m :entries) k nil))

(defn- evict-lru! [m]
  (when-let [k (m :tail)]
    (drop! m k (get-in m [:entries k]))
    (bump m :evictions)
    k))

# -- entries -------------------------------------------------------------

(defn- deadline [ttl]
  (when (and ttl (pos? ttl)) (+ (now) ttl)))

(defn- expired? [e t]
  (when-let [exp (e :expires)] (>= t exp)))

(defn make
  ``An empty store. Options (the [:cache :memory] slice):

    :max-entries    how many entries before the least recently used
                    one is evicted (default 1000)
    :sweep-interval seconds between expiry sweeps; 0 = no sweeper
    :name           what health and logs call it (default :memory)``
  [&opt opts]
  (def cfg (merge defaults (or opts {})))
  @{:name (get cfg :name :memory)
    :max (cfg :max-entries)
    :sweep-interval (cfg :sweep-interval)
    :entries @{}
    :head nil
    :tail nil
    :sweeping false
    :fiber nil
    :started false
    :stats @{:hits 0 :misses 0 :puts 0 :evictions 0 :expirations 0 :sweeps 0}})

(defn lookup
  "The value under `k`, or nil. Counts as a use: the entry moves to the
  front of the recency list."
  [m k]
  (def e (get (m :entries) k))
  (cond
    (nil? e) (do (bump m :misses) nil)

    (expired? e (now))
    (do (drop! m k e)
        (bump m :expirations)
        (bump m :misses)
        nil)

    (do (touch! m k e)
        (bump m :hits)
        (e :value))))

(defn present?
  ``Is `k` there and unexpired? Asking is not using: neither the
  recency order nor the hit counters move, which is what makes this
  usable from a health check or a test.``
  [m k]
  (def e (get (m :entries) k))
  (truthy? (and e (not (expired? e (now))))))

(defn put!
  "Store `v` under `k` for `ttl` seconds (nil = no expiry). Evicts the
  least recently used entry when the store is full."
  [m k v ttl]
  (def e (get (m :entries) k))
  (if e
    (do (put e :value v)
        (put e :expires (deadline ttl))
        (touch! m k e))
    (do
      (when (>= (length (m :entries)) (m :max)) (evict-lru! m))
      (def fresh @{:value v :expires (deadline ttl)})
      (put (m :entries) k fresh)
      (push-front! m k fresh)))
  (bump m :puts)
  v)

(defn delete!
  "Drop one key. True when it was there."
  [m k]
  (if-let [e (get (m :entries) k)]
    (do (drop! m k e) true)
    false))

(defn clear!
  ``Drop every key under `prefix` — everything, when the prefix is
  empty or absent. Returns how many entries went.``
  [m &opt prefix]
  (if (or (nil? prefix) (empty? prefix))
    (let [n (length (m :entries))]
      (put m :entries @{})
      (put m :head nil)
      (put m :tail nil)
      n)
    (do
      (var n 0)
      (each k (keys (m :entries))
        (when (string/has-prefix? prefix k)
          (drop! m k (get-in m [:entries k]))
          (++ n)))
      n)))

(defn sweep!
  "Drop every expired entry. Returns how many went."
  [m]
  (def t (now))
  (var n 0)
  (each k (keys (m :entries))
    (def e (get-in m [:entries k]))
    (when (expired? e t)
      (drop! m k e)
      (bump m :expirations)
      (++ n)))
  (bump m :sweeps)
  n)

(defn entry-count
  "How many entries the store holds, expired ones included (they go on
  the next read or the next sweep)."
  [m]
  (length (m :entries)))

(defn stats
  "Counters plus the current size — what the component's :health
  reports."
  [m]
  (merge (table/clone (m :stats))
         {:store (m :name)
          :entries (entry-count m)
          :max-entries (m :max)
          :sweeping (truthy? (m :sweeping))}))

# -- the sweeper ---------------------------------------------------------

(defn start-sweeper!
  ``Start the expiry sweeper. Idempotent, and a no-op when
  :sweep-interval is 0 — a process that only ever caches without a TTL
  has nothing to sweep.``
  [m]
  (def interval (m :sweep-interval))
  (when (and (not (m :sweeping)) interval (pos? interval))
    (put m :sweeping true)
    (put m :fiber
         (ev/go
           (fn cache-sweeper []
             # `stop-sweeper!` wakes this fiber by cancelling it, and a
             # cancellation delivered *before the fiber's first
             # instruction* — a store stopped in the same turn it was
             # started, which is what a short-lived CLI command does —
             # cannot be caught from inside it at all. So the fiber
             # says here that it exists, and a stop that arrives before
             # this point simply clears :sweeping and lets the loop
             # below fall through on its first test.
             (put m :started true)
             (protect
               (while (m :sweeping)
                 (ev/sleep interval)
                 (when (m :sweeping)
                   (def [ok n] (protect (sweep! m)))
                   (when (and ok (pos? n))
                     (log/debug "swept expired cache entries" :ns log-ns
                                :store (m :name) :dropped n
                                :entries (entry-count m))))))))))
  m)

(defn stop-sweeper!
  "Stop the sweeper. The fiber is woken rather than waited for, so a
  shutdown never sits out a sweep interval."
  [m]
  (put m :sweeping false)
  (when-let [f (m :fiber)]
    (when (m :started)
      (protect (ev/cancel f "cache sweeper stopped"))))
  (put m :fiber nil)
  (put m :started false)
  m)

# -- the :void/cache-store view ------------------------------------------

(defn store
  ``This store as a `:void/cache-store` dictionary. The underlying
  table stays reachable under :memory — the component's :health and
  :stop want it, and so does anyone at a REPL.``
  [m]
  {:name (m :name)
   :values :janet
   :memory m
   :get (fn mem-get [k] (lookup m k))
   :put (fn mem-put [k v ttl] (put! m k v ttl))
   :delete (fn mem-delete [k] (delete! m k))
   :clear (fn mem-clear [prefix] (clear! m prefix))
   :has? (fn mem-has? [k] (present? m k))
   :stats (fn mem-stats [] (stats m))
   :close (fn mem-close [] (stop-sweeper! m) (clear! m) nil)})
