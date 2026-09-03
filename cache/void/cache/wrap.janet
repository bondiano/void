### void/cache/wrap — the decorator.
###
###     (def rates (cache/wrap fetch-rates {:ttl 300}))
###     (rates "usd")   # computed once, then read from the cache
###
### `wrap` is `remember` with the key derived from the call instead of
### written by hand, which is the whole difference and also the whole
### risk: a derived key is only useful if the derivation is the same in
### every process that shares the cache. That is what ./key exists for,
### and it is why an anonymous function has to be given a `:name`
### rather than keyed by whatever `(string f)` prints — a memoized
### function whose key contains a heap address is a cache that misses
### forever in one process and collides across two.
###
### The decorated function is an ordinary function: it caches on the
### way in, forwards everything on the way through, and takes part in
### single-flight like any other `remember`. What it is not is a
### memoize for pure computation in a tight loop — the key building
### alone costs more than most pure functions do. It is for the
### expensive and the remote: a rates table, a rendered fragment, a
### query that summarises a million rows.

(import ./key :as key)
(import ./state :as state)

(defn- fn-name
  "The name a function was defined with, or nil for an anonymous one."
  [f]
  (when (function? f)
    (def n (get (disasm f) :name))
    (when (and (string? n) (not (empty? n))) n)))

(defn key-for
  ``The key a `wrap`ped call is stored under — the handle for
  invalidating one:

      (def rates (cache/wrap fetch-rates {:name :rates}))
      (cache/forget (cache/key-for :rates "usd"))``
  [name & args]
  (key/for-call name args))

(defn forget-call
  "Drop the cached result of one call: `(forget-call :rates \"usd\")`."
  [name & args]
  (state/delete! (key/for-call name args)))

(defn wrap
  ``Memoize `f` through the cache. Returns a function of the same
  arguments that answers from the cache when it can and calls `f` when
  it cannot.

      (def rates (cache/wrap fetch-rates {:ttl 300}))
      (def page  (cache/wrap render {:name :page
                                     :key (fn [user id] id)
                                     :ttl 60}))

  Options:

    :name           what the keys are built from; defaults to the
                    function's own name, and is required for an
                    anonymous one (a key must mean the same thing in
                    every process)
    :key            (fn [& args] k) — the part of the key derived from
                    the arguments, for a call whose arguments are big,
                    unrenderable, or mostly irrelevant to the result
    :ttl            seconds, `:none`, or 0 to compute without storing;
                    nil takes [:cache :ttl]
    :cache-nil      cache a nil result too (see `remember`)
    :single-flight  compute once per key across concurrent fibers
    :when           (fn [& args] bool) — cache only the calls this
                    accepts; the rest go straight through, which is
                    how "everything except the admin's view" is
                    spelled without a second function``
  [f &opt opts]
  (default opts {})
  (def name
    (or (get opts :name)
        (fn-name f)
        (error "cache/wrap needs a :name for an anonymous function — the key is built from it, and it has to be the same name in every process sharing the cache")))
  (def key-fn (get opts :key))
  (def when-fn (get opts :when))
  (def remember-opts
    {:ttl (get opts :ttl)
     :cache-nil (get opts :cache-nil)
     :single-flight (get opts :single-flight)})
  (fn cached [& args]
    (if (and when-fn (not (when-fn ;args)))
      (f ;args)
      (state/remember (if key-fn
                        (string (key/cache-key name) ":" (key/cache-key (key-fn ;args)))
                        (key/for-call name args))
                      remember-opts
                      (fn compute [] (f ;args))))))
