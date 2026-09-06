### void/http/conformance/session — the :void.http/session-store conformance suite.
###
### One set of assertions, run against every session store there is. The
### contract (void/http/session) is four functions — `:load`, `:save`,
### `:delete`, `:sweep` — and a promise about what they do to each
### other: what `save` wrote, `load` gives back as a table the
### middleware can mutate; what `delete` removed is gone; what outlived
### its ttl is gone whether anyone swept or not. Three stores keep that
### promise three different ways (a heap, a redis key with an EX, a row
### with an `expires` column), so this file holds the assertions and
### each store's own test hands it a store:
###
###     (import void/http/conformance/session :as conformance)
###     (conformance/run! "memory" (session/memory-store))
###
### It ships with void/http, not with the tests, so a store written
### outside this repository runs the same suite the three in it do.
###
### Unlike the driver point, the session point has no `normalize`: the
### kernel calls `((store :load) sid)` straight out of the contribution's
### `:make`, so a store missing a key fails inside a request rather than
### at boot. The suite therefore starts by naming what is missing, and
### everything after that goes through the four functions only — the
### memory store's `:entries`, the db store's row count and redis' TTL
### are each visible from exactly one of the three, and an assertion
### that reads them is an assertion about an implementation.
###
### What it does NOT test is what a store does not share: which key a
### session lives under, whether the encoding is jdn, whether `:sweep`
### does any work (redis' is a no-op because the server expires the key
### — the assertion is that the session is *gone*, not that the sweep
### removed it), and the middleware around all of it, which is
### void/http's own suite.

(import void/core/util :as util)

(def- contract-keys
  "The four functions a session store is."
  [:load :save :delete :sweep])

(defn- missing-keys [store]
  (if (dictionary? store)
    (seq [k :in contract-keys :when (not (util/callable? (get store k)))] k)
    contract-keys))

(defn run!
  ``Assert that `store` behaves like a `:void.http/session-store`.
  `name` names the store in the failure messages, because "an expired
  session still loaded" is a different bug in each of them.

  `store` is the dictionary the point's `:make` returns, already bound
  to whatever it needs — a running redis client, a db pool — because
  every assertion here is a call through it.

  The suite works under ids of its own (`void-conf-<pid>-*`) and
  deletes them on the way out, so a shared redis or a shared database
  is left as it was found and a package's other suites can run beside
  it.

  opts:
    :ttl   seconds for the sessions the expiry section lets die
           (default 1 — redis' EX is whole seconds and never shorter
           than one, so this is the floor the contract can express)
    :wait  seconds to wait for that to happen (default :ttl + 0.75)``
  [name store &opt opts]
  (default opts {})
  (defn note [msg] (string name ": " msg))
  (def short-ttl (get opts :ttl 1))
  (def wait (get opts :wait (+ short-ttl 0.75)))
  (def prefix (string "void-conf-" (os/getpid) "-"))
  (defn id [suffix] (string prefix suffix))
  (def ids @[])
  (defn sid [suffix] (def s (id suffix)) (array/push ids s) s)

  # -- the shape ---------------------------------------------------------
  #
  # there is no normalize on this point, so a store that is missing a
  # function does not fail at boot: it fails inside a request, as a
  # nil call on a keyword. Name it here instead.

  (def gaps (missing-keys store))
  (unless (empty? gaps)
    (errorf "%s: not a session store — %s %s callable (a store is %s)"
            name
            (string/join (map string gaps) ", ")
            (if (= 1 (length gaps)) "is not" "are not")
            (string/join (map string contract-keys) ", ")))
  (each k contract-keys
    (assert (util/callable? (store k)) (note (string k " is callable"))))

  (defer (each s ids (protect ((store :delete) s)))

    # -- a session that is not there -------------------------------------

    (assert (nil? ((store :load) (id "unknown")))
            (note "an id the store never saw loads as nil"))
    (def [deleted] (protect ((store :delete) (id "unknown"))))
    (assert deleted (note "and deleting it is not an error"))

    # -- what save wrote, load gives back --------------------------------
    #
    # a session is a janet table with keyword keys and values that are
    # not strings; a store that reshapes it (json's string keys, a
    # struct that cannot be mutated) breaks the middleware, not itself

    (def one (sid "one"))
    (assert (= one ((store :save) one @{:user 7
                                        :name "ada"
                                        :roles [:admin :editor]
                                        :prefs @{:theme :dark}}
                                 60))
            (note "save answers with the id it was given"))
    (def loaded ((store :load) one))
    (assert (table? loaded)
            (note "a session loads as a *table* — the middleware puts into what it is given"))
    (assert (= 7 (loaded :user)) (note "keyword keys survive the round trip"))
    (assert (= "ada" (string (loaded :name))) (note "and string values"))
    (assert (= 2 (length (loaded :roles))) (note "and a sequence of keywords"))
    (assert (= :admin (get-in loaded [:roles 0]))
            (note "whose keywords come back as keywords, which json would not"))
    (assert (= :dark (get-in loaded [:prefs :theme]))
            (note "and nesting survives it"))

    # -- saving again is the same session --------------------------------

    (assert (= one ((store :save) one @{:user 8} 60))
            (note "a second save under the same id answers with it too"))
    (def again ((store :load) one))
    (assert (= 8 (again :user)) (note "and is what loads afterwards"))
    (assert (nil? (get again :roles))
            (note "a save replaces the session — it does not merge into it"))

    # -- delete ------------------------------------------------------------

    ((store :delete) one)
    (assert (nil? ((store :load) one)) (note "a deleted session is gone"))
    (def [twice] (protect ((store :delete) one)))
    (assert twice (note "and deleting it a second time is not an error"))

    # -- two ids do not collide ------------------------------------------

    (def a (sid "a"))
    (def b (sid "b"))
    ((store :save) a @{:who :a} 60)
    ((store :save) b @{:who :b} 60)
    (assert (= :a (get ((store :load) a) :who)) (note "one id holds its own session"))
    (assert (= :b (get ((store :load) b) :who)) (note "and the other holds the other"))

    # -- expiry ------------------------------------------------------------
    #
    # the ttl arrives with every save and it is an idle timeout: the
    # session dies that many seconds after the last one. How it dies is
    # the store's business — the memory store drops the entry on the
    # way past, the db store deletes the row, redis' server does it on
    # its own clock — and the contract is only that it stops loading.

    (def lazy (sid "lazy"))
    (def swept (sid "swept"))
    (def kept (sid "kept"))
    ((store :save) lazy @{:x 1} short-ttl)
    ((store :save) swept @{:x 2} short-ttl)
    ((store :save) kept @{:x 3} 3600)
    (assert ((store :load) lazy) (note "a session with a short ttl is there to begin with"))
    (ev/sleep wait)

    (assert (nil? ((store :load) lazy))
            (note "a session past its ttl does not load"))

    (def [swept-ok] (protect ((store :sweep))))
    (assert swept-ok (note ":sweep is not an error"))
    (assert (nil? ((store :load) swept))
            (note "and an expired session is gone after it — whether it swept or the server did"))
    (assert (= 3 (get ((store :load) kept) :x))
            (note "while a live session is left alone")))

  (printf "%s: session-store conformance OK" name)
  true)
