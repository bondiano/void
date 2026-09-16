### The Datastar mode (M3): the page as state, morphed over SSE.
###
### Claims. With :void/datastar composed the overview carries the
### data-init attribute that opens its stream, /dash/live answers morph
### events (<title> + <body> — the two cuts), a poke re-renders the
### stream's own page, and the logs stream shows a record emitted after
### connect — the ring sink pokes the room, so a log line reaches an open
### page without the page asking. Without datastar (pages-test) the same
### URLs refuse by name and the pages poll; here the htmx poll attribute
### is still present, because the fallback must not wait for the
### experiment to fail.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/dash/live :as live)
(import void/datastar/init :as datastar)

(def open-gate
  "A :void.dash/gate that lets everybody in — the test profile is not :dev."
  (plugin/manifest 'test/open-gate
    :version "0.1.0"
    :requires {:void/dash ">=0.0.1"}
    :contributes {:void.dash/gate [{:name :test/open :fn (fn [_] true)}]}))

(log/set-level! nil :error)

(def boot
  (plugin/start!
    {:plugins ["void/http/init" "void/html/init" "void/htmx/init"
               "void/datastar/init" "void/dash/init" open-gate]
     :profile :test
     :config {:env @{}
              :cli {:log {:level :error}
                    :http {:port 0}}}}))

(defer (plugin/shutdown! boot 3)

  (assert (live/active?) "datastar is composed and its registry runs")

  # the overview opens its stream — and keeps its poll
  (def page (string ((http/with-request {:uri "/dash"}) :body)))
  (assert (string/find "data-init" page)
          "the page carries the stream opener")
  (assert (string/find "datastar.js" page)
          "and the script that acts on it")
  (assert (string/find (string "integrity=\"" datastar/script-integrity) page)
          "pinned, with its integrity hash")
  (assert (string/find "/dash/live" page))
  (assert (string/find "every 5s" page)
          "the htmx poll stays — the fallback does not wait for the experiment")

  # the overview stream: initial morph, then a poke re-renders
  (def resp (http/with-request {:uri "/dash/live"
                                :headers {"datastar-request" "true"}}))
  (assert (= "text/event-stream" (get-in resp [:headers "content-type"])))
  (def frames (resp :body))
  (assert (fiber? frames))
  (assert (string/find "<title>Dash</title>" (resume frames))
          "the first cut is the title")
  (assert (string/find "Overview" (resume frames))
          "the second is the whole body")

  (live/poke! live/overview-room)
  (assert (string/find "<title>Dash</title>" (resume frames))
          "a poke is a full re-render, morphed")
  (resume frames)

  # the logs stream: an emitted record reaches the open page unasked
  (def lresp (http/with-request {:uri "/dash/logs/live"
                                 :headers {"datastar-request" "true"}}))
  (def lframes (lresp :body))
  (resume lframes)                       # title
  (resume lframes)                       # initial body
  (log/set-level! nil :info)
  (log/info "a line for the live page" :ns "my-app.live")
  (log/set-level! nil :error)
  (resume lframes)                       # title again
  (assert (string/find "a line for the live page" (resume lframes))
          "the sink poked the room; the page re-rendered with the record")

  # -- the page's state rides on the stream URL ---------------------------
  #
  # "The page is the state" holds only while the stream sees that state.
  # A filtered log page opened its stream on a bare path once, and every
  # poke morphed the *unfiltered* page over what the operator was reading
  # (ADR-0043 §5): the URL carries the query now, and the stream reads
  # its filters off its own request exactly as the handler does.
  (def filtered (string ((http/with-request {:uri "/dash/logs?ns=my-app.live"}) :body)))
  (assert (string/find "/dash/logs/live?ns=my-app.live" filtered)
          "the page opens its stream on its own state")

  (def fresp (http/with-request {:uri "/dash/logs/live?ns=no-such-namespace"
                                 :headers {"datastar-request" "true"}}))
  (def fframes (fresp :body))
  (resume fframes)                       # title
  (def body (string (resume fframes)))
  (assert (string/find "no-such-namespace" body)
          "the stream re-renders the filter panel the page was rendered with")
  (assert (not (string/find "a line for the live page" body))
          "...and the records it filters to, not every record the ring holds"))

(print "live-test: ok")
