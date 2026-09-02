### The tap inspector (M4): a value leaves the REPL and becomes a page.
###
### Claims. (dash/tap value) returns the value and records it with a
### timestamp; the macro writes the call site down. The ring holds
### [:dash :tap-buffer] entries and evicts honestly — an evicted id is
### a 404 with a sentence, not a crash. The page lists newest first;
### one value unfolds lazily (each expansion is its own request, one
### level deep); an array of dictionaries also renders as a table; the
### JDN copy is the value; and a secret box inside a tapped value
### prints as its reference, never its content — safe by construction.

(import ../test-support/paths)
(import void/core/config :as config)
(import void/core/log :as log)
(import void/test :as test)
(import void/dash :as dash)
(import void/dash/tap :as tapmod)

(log/set-level! nil :error)

# -- the function, the macro, the ring -----------------------------------

(tapmod/configure! 3)

(assert (= 42 (dash/tap* 42)) "tap* returns the value, so it can wrap an expression")
(assert (= :x (dash/tap :x)) "so does the macro")

(def entry (first (tapmod/entries)))
(assert (string/find "tap-test.janet" (or (entry :where) ""))
        "the macro wrote the call site down")
(assert (number? (entry :at)))

(each i [1 2 3 4] (dash/tap* i))
(assert (= 3 (length (tapmod/entries))) "the ring holds [:dash :tap-buffer]")
(assert (= 4 (get (first (tapmod/entries)) :value)) "newest first")

(assert (deep= @[3 4] (map |($ :value) (array ;(reverse (array/slice (tapmod/entries) 0 2))))))

# -- shapes ---------------------------------------------------------------

(assert (tapmod/table-view? [{:a 1} {:a 2}]))
(assert (not (tapmod/table-view? [])) "an empty array is not a table")
(assert (not (tapmod/table-view? {:a 1})))
(assert (= `{:a 1}` (tapmod/to-jdn {:a 1})))
(assert (string/find "function" (tapmod/to-jdn {:f (fn [] 1)}))
        "what JDN cannot say falls back to honest %q")

# -- the pages ------------------------------------------------------------

(def boot
  (test/start! {:plugins ["void/http/init" "void/html/init" "void/htmx/init" "void/dash/init"]
                :profile :dev
                :config {:env @{"TAP_SECRET" "very-secret"}
                         :cli {:http {:port 0}
                               :dash {:tap-buffer 10}
                               :app {:key {:secret "TAP_SECRET"}}}}
                :only [:http/kernel]}))

(defer (test/stop! boot)
  (def c (test/client boot))
  (defn GET [uri] (test/inject c {:uri uri}))

  # a value with depth, a table-shaped value, and a secret box
  (def secret-box (get-in (boot :config) [:values :app :key]))
  (assert (config/secret? secret-box) "the fixture really is a box")
  (def deep-id (get (dash/tap* {:order {:lines [{:sku "a" :qty 2} {:sku "b" :qty 1}]
                                        :key secret-box}}
                               "repl")
                    :order))
  (def tapped (first (tapmod/entries)))

  (def index (GET "/dash/tap"))
  (assert (= 200 (index :status)))
  (assert (string/find "repl" (test/text index)) "the list shows where it came from")
  (assert (string/find "{1 key" (test/text index)) "and its shape")

  (def id (tapped :id))
  (def show (GET (string "/dash/tap/" id)))
  (assert (= 200 (show :status)))
  (def shown (test/text show))
  (assert (string/find ":order" shown) "the root level is unfolded")
  (assert (string/find "/node" shown) "deeper levels are links, not payload")
  (assert (not (string/find "very-secret" shown))
          "a secret box in a tapped value never prints its content")

  # unfold one branch — one request, one level
  (def node (test/inject c {:uri (string "/dash/tap/" id "/node?path=(:order%20:lines)")
                            :headers {"hx-request" "true"}}))
  (assert (= 200 (node :status)))
  (assert (string/find "[2 items]" (test/text node))
          "the branch says its shape")

  (def bad-node (GET (string "/dash/tap/" id "/node?path=%28unbalanced")))
  (assert (string/find "unreadable" (test/text bad-node))
          "a broken path is a sentence, not a parse crash")

  # the table view of an array of dictionaries
  (dash/tap* [{:sku "a" :qty 2} {:sku "b" :qty 1}] "rows")
  (def rows-id (get (first (tapmod/entries)) :id))
  (def rows-page (test/text (GET (string "/dash/tap/" rows-id))))
  (assert (string/find "As a table" rows-page))
  (assert (string/find ":sku" rows-page))

  # the JDN copy is the value
  (def jdn (GET (string "/dash/tap/" rows-id "/jdn")))
  (assert (= 200 (jdn :status)))
  (assert (deep= [{:sku "a" :qty 2} {:sku "b" :qty 1}]
                 (parse (test/text jdn)))
          "what the copy hands out parses back to the value")

  # eviction is honest
  (loop [i :range [0 12]] (dash/tap* i))
  (def gone (GET (string "/dash/tap/" id)))
  (assert (= 404 (gone :status)))
  (assert (string/find "evicted" (test/text gone))
          "an evicted id says what happened to it"))

(print "tap-test: ok")
