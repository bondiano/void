# The wave-5 example is also its smoke test, and it
# tests the way void apps are meant to be tested: test/inject drives the
# full production stack for both representations of the same handler — the
# HTML document and the Datastar morph events — and the live half runs
# against the real :datastar/registry component, poked by the same
# mutation the buttons post.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http :as http)
(import main)

(log/set-level! "void" :error)

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{} :cli {:log {:level :error}
                                  :http {:port 0}
                                  :dev {:netrepl {:enabled false}
                                        :watch {:enabled false}}}}}))

# the composition is valid before anything starts
(assert ((plugin/dry-run opts) :ok) "dry-run passes")

# :datastar/registry on top of the kernel — morph-stream parks its
# connections there (it drags :http/server along as its dependency,
# which is why the config pins :port 0)
(test/with-http [c (merge opts {:only [:http/kernel :datastar/registry]})]

  # -- GET /: one handler, two representations ---------------------------
  (def page (test/inject c {:uri "/"}))
  (assert (= 200 (page :status)))
  (def body (test/text page))
  (assert (string/has-prefix? "<!DOCTYPE html>" body) "full page renders")
  (assert (string/find "datastar.js" body) "the layout loads datastar.js")
  (assert (string/find "integrity=\"sha384-" body) "pinned, with its integrity hash")
  (assert (string/find "data-on:click" body) "the buttons are Datastar actions")
  (assert (string/find "data-signals" body) "the step travels as a signal")
  (assert (string/find "count: 0" body))

  (def morph (test/inject c {:uri "/"
                             :headers {"datastar-request" "true"}}))
  (assert (= "text/event-stream" (get-in morph [:headers "content-type"])))
  (def evs (test/sse-events morph))
  (assert (= 2 (length evs)) "a page with a <body> morphs as title + body")
  (assert (= "datastar-patch-elements" ((evs 0) :event)))
  (assert (string/find "selector title" ((evs 0) :data)))
  (assert (string/find "<title>counter — 0</title>" ((evs 0) :data)))
  (assert (string/find "selector body" ((evs 1) :data)))
  (assert (string/find "count: 0" ((evs 1) :data)))

  # -- actions: signals in, the same page out ----------------------------
  (def inc2 (test/inject c {:uri "/inc"
                            :headers {"datastar-request" "true"}
                            :json {:by 2}}))
  (assert (string/find "count: 2" ((get (test/sse-events inc2) 1) :data))
          "the :by signal drives the step")

  # the same handler still answers a plain request with the document
  (def plain (test/inject c {:method :post :uri "/inc"}))
  (assert (string/has-prefix? "<!DOCTYPE html>" (test/text plain)))
  (assert (string/find "count: 3" (test/text plain)))

  (def dec1 (test/inject c {:uri "/dec"
                            :headers {"datastar-request" "true"}
                            :json {:by 3}}))
  (assert (string/find "count: 0" ((get (test/sse-events dec1) 1) :data)))

  # -- the live half: /live parks in the room, a mutation pokes it -------
  (def live (http/with-request {:uri "/live"}))
  (assert (= "text/event-stream" (get-in live [:headers "content-type"])))
  (def frames (live :body))
  (assert (fiber? frames) "a stream response yields one SSE frame at a time")

  # the initial morph resynchronizes the page on (re)connect
  (assert (string/find "<title>counter — 0</title>" (resume frames)))
  (assert (string/find "count: 0" (resume frames)))
  (def reg (get-in (c :boot) [:system :instances :datastar/registry]))
  (assert (= 1 (length (reg :rooms))) "the stream joined the :counter room")

  # the button's own POST wakes the room; the stream re-renders and
  # pushes the new page
  (test/inject c {:uri "/inc"
                  :headers {"datastar-request" "true"}
                  :json {:by 5}})
  (assert (string/find "<title>counter — 5</title>" (resume frames)))
  (assert (string/find "count: 5" (resume frames)))

  # -- explain-route: the morph key and its middleware are visible -------
  (def ex (http/explain-route "/"))
  (assert (= true (get-in ex [:meta :void.datastar/morph])))
  (assert (index-of :void.datastar/morph (ex :middleware))
          "the morph middleware sits in the resolved chain"))

(print "counter smoke-test ok")
