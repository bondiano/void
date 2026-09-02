### void/cache/state — the runtime: the active cache, the funnel every
### call passes through, and single-flight (SPEC.md §5.11).
###
### The shape is void/db's and void/redis's: one component value in a
### module-level var, a dyn (`cache-dyn`) that overrides it for a
### scope, and one funnel where the counters, the logging and the error
### policy live. void/obs (wave 3) hangs its instrumentation on the
### same funnel.
###
### Three decisions are made here rather than in a backend, because all
### three have to hold whichever backend is underneath.
###
### **A cache that throws breaks what it was supposed to make faster.**
### A redis that went away should cost latency, not availability: with
### `[:cache :on-error] :degrade` (the default) a failing store reads
### as a miss, a failing write is dropped, and the application computes
### what it needed exactly as it would have on a cold cache. The
### failures are counted and logged (at most one line every ten
### seconds — an outage that logs per request is an outage twice), and
### `:raise` is there for the caller who would rather know. This is the
### one place where swallowing an error is the correct behaviour, and
### it is worth being explicit about why: a cache has no data of its
### own, so there is nothing to lose by ignoring it.
###
### **Two fibers that miss the same key should compute once.** A cold
### key on a busy route is a thundering herd: the more traffic there
### is, the more copies of the same expensive computation run at the
### same moment, which is the opposite of what a cache is for. The
### first fiber to miss computes; the others park on a channel and take
### its answer, error included. This is per process — a real
### cross-process lock is a different feature with a different failure
### mode (a holder that dies leaves a lock), and `[:cache
### :single-flight] false` turns it off. What it is not is a
### correctness mechanism: a value can still be computed twice, by two
### processes, or by one that raced with an expiry.
###
### **Absence is a value worth caching, but only on purpose.** A store
### answers a miss with nil, so there is no room in the protocol for
### "nil is what was cached" — which matters, because the misses that
### hurt are exactly the ones that recompute nothing (a lookup of a row
### that does not exist, hammered by a crawler). `:cache-nil` stores a
### sentinel instead, and `fetch` is the reader that can still tell the
### two apart. On a store that cannot round-trip a keyword (redis with
### the :raw codec, which declares :values :bytes) asking for it is an
### error rather than a sentinel that comes back as the string
### ":void.cache/nil" and gets served to somebody as data.

(import void/core/log :as log)
(import ./key :as key)
(import ./store :as store)

(def log-ns
  "Log namespace of the cache funnel — spelled out, since the
  file-derived default would carry the install path."
  "void.cache")

(def cache-dyn
  "Dynamic binding: cache override — set it to run a scope against a
  cache other than the started :cache/store component (tests, tooling,
  a second cache)."
  :void.cache/cache)

(def nil-sentinel
  "What a cached nil is stored as. A keyword, so a jdn or Janet-valued
  store brings it back as itself and nothing an application would
  plausibly cache collides with it."
  :void.cache/nil)

(def error-log-interval
  "Seconds between two store-failure log lines. The counter still
  counts every one of them."
  10)

(var current-cache
  "The value of the running :cache/store component (set by its
  :start). One per process, like plugin/current-boot."
  nil)

(defn active-cache
  "The cache this fiber runs against: the `cache-dyn` override, else
  the started component."
  []
  (or (dyn cache-dyn)
      current-cache
      (error "void/cache is not started — no :cache/store component (or bind the cache-dyn dynamic)")))

(defn active-store
  "The backend behind the active cache."
  []
  ((active-cache) :store))

(defn key-prefix
  "The string every key built through this cache is prefixed with."
  []
  ((active-cache) :prefix))

(defn full-key
  ``A key as the store sees it: the application's spelling (see
  key/cache-key) under the cache prefix.``
  [k]
  (string (key-prefix) (key/cache-key k)))

(defn enabled?
  "False when `[:cache :enabled] false` turned this cache into a
  well-behaved hole: every read misses, every write is dropped, and
  nothing else in the application has to know."
  []
  (not= false ((active-cache) :enabled)))

# -- counters and the error policy ---------------------------------------

(defn- bump [cache k &opt by]
  (def s (cache :stats))
  (put s k (+ (or by 1) (s k))))

(defn- note-failure [cache what err]
  (bump cache :errors)
  (def t (os/clock :monotonic))
  (when (> (- t (get cache :last-error-at -1e9)) error-log-interval)
    (put cache :last-error-at t)
    (log/warn "the cache store failed — degrading to a miss" :ns log-ns
              :store (get-in cache [:store :name])
              :operation what
              :err (if (dictionary? err) (get err :message (describe err)) (describe err))))
  nil)

(defn- attempt
  ``Run a store operation under the configured error policy: with
  `:degrade` a failure is counted, occasionally logged, and answered
  with `fallback`; with `:raise` it is the caller's problem.``
  [cache what f &opt fallback]
  (def [ok res] (protect (f)))
  (cond
    ok res
    (= :raise (get cache :on-error :degrade)) (error res)
    (do (note-failure cache what res) fallback)))

# -- ttl -----------------------------------------------------------------

(defn resolve-ttl
  ``Seconds to live for a write: nil takes the cache's default,
  `:none` means no expiry, and a number is itself. 0 means "do not
  store this", which is how a route or a call opts out of a default
  its group set.``
  [cache ttl]
  (def v (if (nil? ttl) (get cache :ttl) ttl))
  (cond
    (= :none v) nil
    (nil? v) nil
    v))

(defn- skip-write? [cache ttl]
  (def v (if (nil? ttl) (get cache :ttl) ttl))
  (and (number? v) (not (pos? v))))

# -- reads ---------------------------------------------------------------

(defn- decode-hit [v]
  (if (= nil-sentinel v) nil v))

(defn fetch
  ``The reader that can tell a cached nil from a miss: `[found? value]`.

      (def [found v] (cache/fetch "user:42"))

  Everything else here is written in terms of this one.``
  [k]
  (def cache (active-cache))
  (if-not (enabled?)
    (do (bump cache :misses) [false nil])
    (let [st (cache :store)
          raw (attempt cache :get (fn [] ((st :get) (full-key k))))]
      (if (nil? raw)
        (do (bump cache :misses) [false nil])
        (do (bump cache :hits) [true (decode-hit raw)])))))

(defn get-value
  "The value under `k`, or `dflt` (nil) when it is not cached. A cached
  nil is indistinguishable from a miss here — `fetch` is the reader
  that tells them apart."
  [k &opt dflt]
  (def [found v] (fetch k))
  (if (and found (not (nil? v))) v dflt))

(defn has?
  "Is `k` cached? Cheaper than a read on a store that can answer
  without moving the value (redis: EXISTS)."
  [k]
  (def cache (active-cache))
  (if-not (enabled?)
    false
    (truthy? (attempt cache :has? (fn [] (((cache :store) :has?) (full-key k))) false))))

(defn get-many
  ``The values under `ks`, in order, nil where a key is not cached. One
  round trip on a store that can do it (redis: MGET).``
  [ks]
  (def cache (active-cache))
  (if-not (enabled?)
    (do (bump cache :misses (length ks)) (map (fn [_] nil) ks))
    (let [st (cache :store)
          full (map full-key ks)
          raw (or (attempt cache :get-many (fn [] ((st :get-many) full)))
                  (map (fn [_] nil) ks))]
      (def out @[])
      (each v raw
        (if (nil? v)
          (do (bump cache :misses) (array/push out nil))
          (do (bump cache :hits) (array/push out (decode-hit v)))))
      out)))

# -- writes --------------------------------------------------------------

(defn- encode-value [cache v]
  (if (nil? v)
    (do
      (when (= :bytes (get-in cache [:store :values]))
        (errorf (string "cannot cache a nil in the %q store: it encodes values as bytes "
                        "(a :raw redis codec), so the sentinel a cached nil is stored as "
                        "would come back as text. Configure a codec that round-trips Janet "
                        "values ([:cache-redis :codec] :jdn) or leave :cache-nil off")
              (get-in cache [:store :name])))
      nil-sentinel)
    v))

(defn put!
  ``Store `v` under `k` for `ttl` seconds — nil takes `[:cache :ttl]`,
  `:none` means no expiry, 0 means do not store. Returns `v`, so it
  drops into a computation without restructuring it.

  A nil `v` is only stored when `:cache-nil` asked for it (see
  `remember`); on its own, `(put! k nil)` deletes nothing and stores
  nothing, because "the value is nil" and "there is no value" are the
  same sentence to a store.``
  [k v &opt ttl]
  (def cache (active-cache))
  (when (and (enabled?) (not (nil? v)) (not (skip-write? cache ttl)))
    (bump cache :puts)
    (attempt cache :put
             (fn [] (((cache :store) :put) (full-key k) v (resolve-ttl cache ttl)))))
  v)

(defn put-many!
  "Store several entries — `{k v}` or `[[k v] ...]` — under one ttl.
  One round trip on a store that can do it."
  [entries &opt ttl]
  (def cache (active-cache))
  (def items (seq [[k v] :in (if (dictionary? entries) (pairs entries) entries)
                   :when (not (nil? v))]
               [(full-key k) v]))
  (when (and (enabled?) (not (empty? items)) (not (skip-write? cache ttl)))
    (bump cache :puts (length items))
    (attempt cache :put-many
             (fn [] (((cache :store) :put-many) items (resolve-ttl cache ttl)))))
  nil)

(defn delete!
  "Drop one key. True when it was there (as far as the store knows)."
  [k]
  (def cache (active-cache))
  (bump cache :deletes)
  (truthy? (attempt cache :delete (fn [] (((cache :store) :delete) (full-key k))) false)))

(defn forget
  "Drop keys. The plural of `delete!`, spelled the way an invalidation
  reads."
  [& ks]
  (var n 0)
  (each k ks (when (delete! k) (++ n)))
  n)

(defn clear!
  ``Drop every key this cache holds — everything under `[:cache
  :prefix]`, and nothing else. On a shared redis that is a walk of the
  keyspace rather than one command, and it is not atomic: keys written
  while it walks may survive it.

  With an *empty* prefix "everything under the prefix" is every key
  the store holds — on a shared redis, keys that were never this
  cache's. That is refused unless the caller says `(clear!
  :everything)`, which is the word for exactly that.``
  [&opt confirm]
  (def cache (active-cache))
  (def prefix (key-prefix))
  (when (and (or (nil? prefix) (empty? prefix)) (not= :everything confirm))
    (error (string "cache/clear! with an empty [:cache :prefix] would drop every key "
                   "the store holds, not just this cache's — set a prefix, or call "
                   "(cache/clear! :everything) to mean exactly that")))
  (or (attempt cache :clear (fn [] (((cache :store) :clear) (key-prefix))) 0) 0))

(defn incr!
  ``Add `delta` (1) to the number under `k` and return it, storing it
  with `ttl` when the key is new. Exact wherever the store implements
  it (redis: INCRBY); on a store where this module has to read-add-
  write, exact within one process and no more — see store/atomic-incr?.``
  [k &opt delta ttl]
  (default delta 1)
  (def cache (active-cache))
  (if-not (enabled?)
    nil
    (attempt cache :incr
             (fn [] (((cache :store) :incr) (full-key k) delta (resolve-ttl cache ttl))))))

# -- single flight -------------------------------------------------------

(defn- flight-options [cache opts]
  (def sf (get opts :single-flight))
  (if (nil? sf) (not= false (cache :single-flight)) sf))

(defn- flight-leaders
  # key -> the root fiber of the task leading that key's flight —
  # created lazily so a cache value from an older `make` still works
  [cache]
  (or (cache :flight-leaders)
      (let [t @{}] (put cache :flight-leaders t) t)))

(defn- single-flight
  ``Run `f` once per key, however many fibers ask at the same moment.
  The first caller computes; the rest park on a channel of their own
  and take whatever it produced — the value, or the error, which is
  the important half: a herd that all recompute after a failure is the
  herd this exists to prevent.

  The one caller who must not park is the leader itself: a recursive
  `remember` on the same key — cache/wrap on a function that calls
  itself with the same arguments — would park the leading task on its
  own flight, a deadlock that also leaves the flight entry behind,
  poisoning the key for every later caller. So a re-entry from the
  task already computing a key (its root fiber, which `protect` and
  nesting do not change) just computes: single-flight dedupes
  concurrent strangers, and a recursion is neither concurrent nor a
  stranger.``
  [cache k f]
  (def flights (cache :in-flight))
  (def leaders (flight-leaders cache))
  (cond
    (= (fiber/root) (get leaders k))
    (f)

    (if-let [waiters (get flights k)]
      (do
        (bump cache :flight-waits)
        (def ch (ev/chan 1))
        (array/push waiters ch)
        (def [status v] (ev/take ch))
        (if (= :ok status) v (error v)))
      (do
        (def waiters @[])
        (put flights k waiters)
        (put leaders k (fiber/root))
        (def [ok res] (protect (f)))
        (put leaders k nil)
        (put flights k nil)
        (def message [(if ok :ok :err) res])
        (each ch waiters (ev/give ch message))
        (if ok res (error res))))))

(defn in-flight
  "How many keys are being computed right now — a number worth looking
  at when a cache seems to be doing more work than it should."
  []
  (length ((active-cache) :in-flight)))

# -- read-through --------------------------------------------------------

(defn remember
  ``The value under `k`, or — when there is none — the result of
  `thunk`, stored and returned.

      (cache/remember "rates" 300 fetch-rates)
      (cache/remember "rates" {:ttl 300 :cache-nil true} fetch-rates)

  The middle argument is a ttl (seconds, `:none` for no expiry, 0 for
  "compute but do not store") or an options dictionary:

    :ttl            as above; nil takes [:cache :ttl]
    :cache-nil      store a nil result too, so a lookup that found
                    nothing is not repeated on every request (false)
    :single-flight  compute once per key across concurrent fibers
                    (defaults to [:cache :single-flight])
    :refresh        skip the read and recompute, storing the result —
                    an invalidation that leaves no window where the
                    key is missing``
  [k ttl-or-opts thunk]
  (def opts (if (dictionary? ttl-or-opts) ttl-or-opts {:ttl ttl-or-opts}))
  (def cache (active-cache))
  (def ttl (get opts :ttl))
  (def cache-nil (truthy? (get opts :cache-nil)))

  (defn compute []
    (def v (thunk))
    (when (or cache-nil (not (nil? v)))
      (def stored (if (nil? v) (encode-value cache v) v))
      (when (and (enabled?) (not (skip-write? cache ttl)))
        (bump cache :puts)
        (attempt cache :put
                 (fn [] (((cache :store) :put) (full-key k) stored (resolve-ttl cache ttl))))))
    v)

  (if (get opts :refresh)
    (compute)
    (let [[found v] (fetch k)]
      (if found
        v
        (if (flight-options cache opts)
          (single-flight cache (full-key k) compute)
          (compute))))))

# -- introspection -------------------------------------------------------

(defn stats
  ``What this cache has been doing: hits, misses, writes, deletes,
  store failures, single-flight waits — plus whatever the store counts
  and its hit rate, which is the number anyone actually asks for.``
  []
  (def cache (active-cache))
  (def s (table/clone (cache :stats)))
  (def looks (+ (s :hits) (s :misses)))
  # the store's counters go in first and the funnel's on top: both
  # count the same events one layer apart, and the funnel is the layer
  # that saw every call (a degraded read never reached the store)
  (merge (let [[ok st] (protect (((cache :store) :stats)))] (if ok st {}))
         s
         {:hit-rate (if (pos? looks) (/ (s :hits) looks) 0)
          :in-flight (length (cache :in-flight))
          :prefix (cache :prefix)
          :ttl (get cache :ttl)
          :enabled (enabled?)}))

(defn make
  ``A cache value — a normalized store, a prefix, a default ttl and the
  policies — without a plugin bootstrap behind it. `cache-dyn` takes
  one of these, which is what makes every layer above a store testable
  on its own.``
  [st &opt opts]
  (default opts {})
  @{:store (store/normalize st)
    :prefix (get opts :prefix "")
    :ttl (get opts :ttl)
    :enabled (not= false (get opts :enabled))
    :single-flight (not= false (get opts :single-flight))
    :on-error (get opts :on-error :degrade)
    :in-flight @{}
    :flight-leaders @{}
    :stats @{:hits 0 :misses 0 :puts 0 :deletes 0 :errors 0 :flight-waits 0}})
