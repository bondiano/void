### void/cache/conformance/store — the :void/cache-store conformance suite.
###
### One set of assertions, run against every backend there is. The
### contract (void/cache/store) says a store is four functions, that
### `normalize` fills the other six in, and that two declarations —
### `:shared?` and `:values` — are what a caller reads instead of the
### store's name. A suite that only ever ran against the memory store
### would be a suite that never checked the claim, so this file holds
### the assertions and each backend's own test hands it a store:
###
###     (import void/cache/conformance/store :as conformance)
###     (conformance/run! "memory" (memory/store (memory/make ...)))
###
### It ships with void/cache, not with the tests, so a store written
### outside this repository runs the same suite against the same
### contract it will be plugged into.
###
### It takes the store **un-normalized**, and that is not an oversight:
### `atomic-incr?` is a claim about what the backend shipped, and once
### `normalize` has merged the read-add-write fallback in there is no
### way left to tell the two apart. The suite normalizes it itself, the
### way the cache does.
###
### Everything branches on declarations rather than on the store's
### name. `:values :bytes` means keywords do not survive the round
### trip, so the structure assertion is not run; `:shared?` true means
### the value handed back was decoded, so mutating it cannot reach the
### store. A backend whose name the suite recognised would be a suite
### that stops working the day somebody writes a fifth one.
###
### It runs in a database somebody else is also in. Every key carries a
### prefix with this process's pid, `clear` is only ever called on that
### prefix, and a `defer` takes the keys away on the way out — the same
### rule the redis suites keep, for the same reason: the backend named
### may be production's.
###
### What it does NOT test is what a backend does not share: the LRU and
### its recency list, the sweeper fiber, SCAN batching, the codec
### registry. Those live in the backend's own suite, next to the thing
### that has them.

(import ../store :as store)

(defn run!
  ``Assert that `store0` behaves like a `:void/cache-store`. `name`
  names the backend in the failure messages, because "the counter did
  not expire" is a different bug in each of them.

  `store0` is the raw store dictionary, not a normalized one — see the
  module docstring.

  The suite works under `void-conformance-<pid>-` and clears exactly
  that prefix on the way out; the rest of the store is untouched, so it
  can share a redis database with whatever else lives there.

  opts:
    :ttl     the short ttl the expiry section uses, in seconds
             (default 0.1) — a store whose clock is a network away
             wants a longer one
    :settle  how long past a ttl to wait before calling it expired
             (default 0.3)``
  [name store0 &opt opts]
  (default opts {})
  (def st (store/normalize store0))
  (defn note [msg] (string name ": " msg))

  (def base (string "void-conformance-" (os/getpid) "-"))
  (defn k [s] (string base s))
  (def brief (get opts :ttl 0.1))
  (def settle (get opts :settle 0.3))
  # a counter's ttl is set once, on its first increment, and the
  # second increment and its assertion have to land inside it — so it
  # gets three times the window a plain entry does
  (def counter-ttl (* 3 brief))

  # what the backend shipped, recorded before normalize hid it
  (def own-incr (truthy? (get store0 :incr)))
  (def janet? (= :janet (st :values)))

  # `protect`: a cleanup that raises because the connection died would
  # bury the assertion that failed first
  (defer (protect ((st :clear) base))

    # -- the shape -------------------------------------------------------

    (assert (keyword? (st :name)) (note "a store names itself with a keyword"))
    (each key [:get :put :delete :clear :get-many :put-many :has? :incr :stats :close]
      (assert (function? (st key))
              (note (string key " is callable after normalize — the cache never checks"))))
    # :values and :shared? were checked by normalize; what is left to
    # say is that :shared?, when the store speaks, is an answer and not
    # a value that merely reads as one (nil is the documented "no")
    (unless (nil? (get store0 :shared?))
      (assert (boolean? (get store0 :shared?))
              (note ":shared? is declared as a boolean — several processes either see one set of entries or they do not")))
    # :close is not called: it is the component's to call, and on the
    # memory store it takes the entries with it — a suite that closed
    # the backend it was handed could not be run twice against one.

    # -- get and put -----------------------------------------------------

    (assert (nil? ((st :get) (k "absent")))
            (note "a key that was never written reads as nil"))

    (if janet?
      (let [v {:a [1 2 :three] :b "text" :c {:nested true}}]
        ((st :put) (k "shape") v nil)
        (assert (deep= v ((st :get) (k "shape")))
                (note "a :janet store gives back the value it was given — keywords, nesting and all")))
      (let [v "plain-bytes"]
        ((st :put) (k "shape") v nil)
        (assert (= v (string ((st :get) (k "shape"))))
                (note "a :bytes store gives back the bytes it was given"))))

    ((st :put) (k "over") 1 nil)
    ((st :put) (k "over") 2 nil)
    (assert (= 2 (if janet? ((st :get) (k "over"))
                   (scan-number (string ((st :get) (k "over"))))))
            (note "a second write replaces the first"))

    (assert ((st :delete) (k "over"))
            (note "an overwrite left one entry behind, not two"))

    # -- the ttl is the store's, on the store's clock ---------------------

    ((st :put) (k "forever") 1 nil)
    ((st :put) (k "brief") 1 brief)
    (assert (not (nil? ((st :get) (k "brief"))))
            (note "an entry is there before its ttl runs out"))
    (ev/sleep (+ brief settle))
    (assert (nil? ((st :get) (k "brief")))
            (note "and gone after it — an expired entry reads as absent"))
    (assert (not ((st :has?) (k "brief")))
            (note "has? agrees that it expired"))
    (assert (not (nil? ((st :get) (k "forever"))))
            (note "no ttl means no expiry"))

    # -- has? ------------------------------------------------------------

    (assert (boolean? ((st :has?) (k "forever")))
            (note "has? answers true or false, not a count"))
    (assert ((st :has?) (k "forever")) (note "and true for a key that was written"))
    (assert (not ((st :has?) (k "never-written")))
            (note "and false for a key nothing wrote"))
    (assert (nil? ((st :get) (k "never-written")))
            (note "asking whether a key is there does not create it"))

    # asking is not using: a store that counts hits must not count this
    # one, or a health check would warm its own statistics
    (let [before (get ((st :stats)) :hits)]
      (when (number? before)
        ((st :has?) (k "forever"))
        (assert (= before (get ((st :stats)) :hits))
                (note "asking whether a key is there is not using it"))))

    (assert (not (nil? ((st :get) (k "forever"))))
            (note "and has? left the entry where it was"))

    # -- several at once --------------------------------------------------

    ((st :put-many) [[(k "m1") 1] [(k "m2") 2]] nil)
    (assert (not (nil? ((st :get) (k "m1")))) (note "put-many wrote the first"))
    (assert (not (nil? ((st :get) (k "m2")))) (note "and the second"))

    (def many ((st :get-many) [(k "m1") (k "m2") (k "m-gone")]))
    (assert (= 3 (length many))
            (note "get-many answers one value per key asked for"))
    (assert (nil? (get many 2))
            (note "with nil where the key was not there — the holes keep the order"))
    (when janet?
      (assert (deep= @[1 2 nil] many)
              (note "and the values come back in the order they were asked for")))

    (assert (empty? ((st :get-many) []))
            (note "get-many of nothing is nothing, not an error"))

    # -- counters ---------------------------------------------------------
    #
    # The read-add-write fallback stores a number and reads it back as
    # one, which is a thing only a :janet store does; a :bytes store
    # that wants a counter implements :incr itself (redis does, with
    # INCRBY, which is also what makes it exact across processes). So
    # the section runs when the increment can work at all, and the
    # declarations say whether it can.
    (when (or own-incr janet?)
      (assert (= 1 ((st :incr) (k "hits") 1 counter-ttl))
              (note "an increment of a key nothing wrote starts at zero"))
      (assert (= 6 ((st :incr) (k "hits") 5 counter-ttl))
              (note "and adds the delta to what is there"))
      (ev/sleep (+ counter-ttl settle))
      (assert (not ((st :has?) (k "hits")))
              (note "the counter carried the ttl it was created with"))

      # a store that shipped :incr claims the increment is atomic —
      # that is what `atomic-incr?` tells the cache layer — and the
      # claim is checked by overlapping the increments: eight fibers,
      # each adding one, and none of them lost
      (when own-incr
        (def done (ev/chan 8))
        (for _ 0 8
          (ev/go (fn [] ((st :incr) (k "shared") 1 counter-ttl)) nil done))
        (for _ 0 8 (ev/take done))
        (assert (= 8 ((st :incr) (k "shared") 0 counter-ttl))
                (note "eight overlapping increments land as eight — the store's :incr is atomic")))

      ((st :put) (k "text") "hello" nil)
      (def [ok err] (protect ((st :incr) (k "text") 1 nil)))
      (assert (not ok) (note "incrementing something that is not a number is an error"))
      (assert (or (string? err) (dictionary? err))
              (note "and the error says so rather than storing nonsense")))

    # -- delete -----------------------------------------------------------

    ((st :put) (k "doomed") 1 nil)
    (assert ((st :delete) (k "doomed")) (note "deleting what is there answers true"))
    (assert (not ((st :delete) (k "doomed")))
            (note "deleting it again is not an error, just false"))
    (assert (nil? ((st :get) (k "doomed"))) (note "and it is gone"))

    # -- clear takes a prefix, and only that prefix ------------------------
    #
    # the reason `clear` is not FLUSHDB: this store's database belongs
    # to whoever else is in it, and a cache nobody dares call clear on
    # is a cache with no invalidation
    (def scope (k "scoped:"))
    ((st :put) (string scope "a") 1 nil)
    ((st :put) (string scope "b") 2 nil)
    ((st :put) (k "outside") 3 nil)

    (def dropped ((st :clear) scope))
    (assert (number? dropped) (note "clear says how many entries went"))
    (assert (= 2 dropped) (note "which is the two that were under the prefix"))
    (assert (nil? ((st :get) (string scope "a"))) (note "and they are gone"))
    (assert (nil? ((st :get) (string scope "b"))) (note "both of them"))
    (assert (not (nil? ((st :get) (k "outside"))))
            (note "while a key outside the prefix is untouched — clear never flushes"))

    # -- stats -------------------------------------------------------------

    (assert (dictionary? ((st :stats)))
            (note "stats answers a dictionary, whatever is in it"))

    # -- what the store hands back ------------------------------------------
    #
    # No store promises a copy, and the two shipped backends differ:
    # the memory store hands back the very table it was given, redis
    # decodes a fresh one. The contract's claim is narrower than either
    # — and it is a claim about `:shared?`, not about the name: a store
    # whose reads alias its own entries is a store living in one heap.
    (when janet?
      (def held @{:count 1})
      ((st :put) (k "mutable") held nil)
      (def first-read ((st :get) (k "mutable")))
      (assert (deep= @{:count 1} first-read)
              (note "a table cached and read back is the table that was cached"))
      (when (dictionary? first-read)
        (put first-read :count 2)
        (def after (get ((st :get) (k "mutable")) :count))
        (assert (or (= 1 after) (= 2 after))
                (note "a read either aliases the store's value or is a copy of it — nothing else"))
        (when (= 2 after)
          (assert (not (store/shared? st))
                  (note (string "mutating a read changed what the store holds, so the entries "
                                "live in this heap — a store that does that cannot declare :shared? true"))))
        (when (store/shared? st)
          (assert (= 1 after)
                  (note "a shared store decoded what it handed back, so mutating it reached nothing"))))))

  (printf "%s: cache-store conformance OK" name)
  true)
