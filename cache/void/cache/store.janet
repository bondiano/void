### void/cache/store — the :void/cache-store contract (SPEC.md §5.11,
### ROADMAP 2.3).
###
### Two interfaces, deliberately, and the split is the whole design of
### this plugin:
###
###   :void/cache        what you depend on — a cache, with a prefix, a
###                      default TTL, single-flight and an error policy
###                      (the :cache/store component, see ./state)
###   :void/cache-store  what you implement — four functions over
###                      strings and values (this module)
###
### A backend is a plain dictionary produced by a store component's
### :start; the component declares :provides [:void/cache-store], so
### the config picks the implementation and no code above names one.
### Required keys:
###
###   :get     (fn [key] value-or-nil)    — nil is "not here"
###   :put     (fn [key value ttl])       — ttl in seconds, nil = forever
###   :delete  (fn [key] deleted?)
###   :clear   (fn [key-prefix] n)        — drop what is under a prefix
###
### `:clear` takes a prefix rather than clearing everything, and that
### is not a detail: the redis backend shares a database with whatever
### else lives there, and a cache whose "clear" was FLUSHDB would be a
### cache nobody dares call clear on. An empty prefix means everything
### the store holds — for the memory store, everything there is.
###
### Optional keys, each with a documented fallback, so a working
### backend stays four functions:
###
###   :get-many (fn [keys] values)        — falls back to a loop of :get
###   :put-many (fn [pairs ttl])          — falls back to a loop of :put
###   :has?     (fn [key] bool)           — falls back to (not (nil? get))
###   :incr     (fn [key delta ttl] n)    — falls back to get/add/put
###   :stats    (fn [] {...})             — falls back to {}
###   :close    (fn [])                   — falls back to nothing
###
### plus two declarations:
###
###   :name    keyword, for logs and health
###   :shared? boolean (default false) — do several processes see the
###            same entries? A store that does not say lives in one
###            heap, which is what a store written without the question
###            in mind is; `[:deploy :shape] :fleet` refuses one at
###            start, because `cache/forget` on a per-process store
###            clears one replica out of N and the stale answer stays
###            on the others (ADR-0030)
###   :values  :janet (default) — the store gives back what it was
###            given, keywords and tables and all — or :bytes, when it
###            round-trips through an encoding that does not preserve
###            Janet types (redis with the :raw codec). ./state refuses
###            to cache a nil on a :bytes store rather than let the
###            sentinel come back as a string that looks like data.
###
### One thing no store promises: that the value you get back is a copy.
### The memory store hands back the very table it was given, because a
### deep copy on every read costs more than the cache saves and Janet
### has no cheap one; the redis store hands back a fresh value every
### time, because it decoded it. Code that mutates what it read works
### on redis and quietly poisons the memory cache — so cache values you
### intend to share as `(freeze v)`, and let the type system remind
### you. `normalize` cannot check this, but a test in this package
### pins the asymmetry so it stays documented rather than discovered.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def- required [:get :put :delete :clear])

(def- optional [:get-many :put-many :has? :incr :stats :close])

(def value-kinds
  "What a store's :values declaration may say."
  {:janet true :bytes true})

(defn normalize
  ``Validate a store dictionary and fill in the documented fallbacks.
  Returns a frozen store value; throws with the offending key on any
  contract violation.``
  [st]
  (unless (dictionary? st)
    (errorf "cache store must be a dictionary, got %q" st))
  (def name (get st :name :anonymous))
  (unless (keyword? name)
    (errorf "cache store :name must be a keyword, got %q" name))
  (each k required
    (unless (callable? (get st k))
      (errorf "cache store %q: %q must be a function, got %q" name k (get st k))))
  (each k optional
    (when-let [f (get st k)]
      (unless (callable? f)
        (errorf "cache store %q: %q must be a function, got %q" name k f))))
  (def values (get st :values :janet))
  (unless (in value-kinds values)
    (errorf "cache store %q: :values must be :janet or :bytes, got %q" name values))

  (def get- (st :get))
  (def put- (st :put))
  # recorded before the fallback is merged in: everything below wants
  # to know whether the increment is the store's own (atomic wherever
  # the store is shared) or this module's read-add-write
  (def own-incr (truthy? (get st :incr)))
  (freeze
    (merge
      @{:name name
        :values values
        :shared? false
        :get-many (fn get-many [ks] (map get- ks))
        :put-many (fn put-many [pairs ttl]
                    (each [k v] pairs (put- k v ttl))
                    nil)
        :has? (fn has? [k] (not (nil? (get- k))))
        # Not atomic across processes, and it cannot be: read, add,
        # write. Within one process it is — nothing yields between the
        # three, because none of them is an ev operation — so an
        # in-process counter is exact and a shared one is not. A store
        # that can do better says so by implementing :incr; the redis
        # backend does (INCRBY).
        :incr (fn incr [k delta ttl]
                (def cur (get- k))
                (unless (or (nil? cur) (number? cur))
                  (errorf "cache: %q holds %q, which is not a number to increment" k cur))
                (def next (+ (or cur 0) delta))
                (put- k next ttl)
                next)
        :stats (fn stats [] {})
        :close (fn close [] nil)}
      st
      {:atomic-incr own-incr})))

(defn shared?
  "True when several processes see the same entries — the question
  `[:deploy :shape] :fleet` asks of every store it can reach
  (ADR-0030)."
  [st]
  (truthy? (get st :shared?)))

(defn atomic-incr?
  "True when the store implements :incr itself — that is, when the
  counter is exact even with several processes sharing the store."
  [st]
  (truthy? (get st :atomic-incr)))
