### void/ws-htmx over a real socket: the page's side of the htmx ws
### extension is a fragment marked for an out-of-band swap, and the
### only way to know it works is to read the bytes that reach a peer.

(import ../test-support/paths)
(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/router :as router)
(require "void/http/init")
(require "void/html/init")
(require "void/htmx/init")
(import void/ws :as ws)
(import void/ws/htmx :as wshtmx)
(import void/ws/client :as wsc)

(log/set-level! "void" :error)

# -- the fragment, without a socket in sight -----------------------------

(assert (= "<li id=\"m-1\" hx-swap-oob=\"true\">hi</li>"
           (wshtmx/fragment [:li {:id "m-1"} "hi"]))
        "an element with an id is marked for an out-of-band swap and rendered")

(assert (= "<div id=\"log\" hx-swap-oob=\"beforeend\"><p>line</p></div>"
           (wshtmx/fragment [:div {:id "log" :hx-swap-oob "beforeend"}
                             [:p "line"]]))
        "an element that already says how it wants to be swapped keeps it")

(assert (= "<span id=\"a\" hx-swap-oob=\"innerHTML\">1</span>"
           (wshtmx/fragment [:span {:id "a"} 1] :inner-html))
        "and a swap style is spelled the way htmx spells it")

(assert (string/find "hx-swap-oob" (wshtmx/fragment [[:div {:id "a"} 1]
                                                     [:div {:id "b"} 2]]))
        "a list of elements is a list of out-of-band swaps")

(assert (= "<div id=\"x\">ready</div>" (wshtmx/fragment "<div id=\"x\">ready</div>"))
        "already-rendered HTML passes through — the caller knows what it has")

(def [ok err] (protect (wshtmx/fragment [:div "no id"])))
(assert (not ok) "an element htmx could not target is refused")
(assert (string/find "by id" (string err)) "and the error says why")

# -- the envelope htmx sends ---------------------------------------------

(def envelope
  {:type :text
   :data (json/encode {"message" "hello" "room" "lobby"
                       "HEADERS" {"HX-Trigger" "say"}})})

(assert (= "hello" ((wshtmx/fields envelope) :message)))
(assert (nil? ((wshtmx/fields envelope) :HEADERS))
        "htmx's own headers are not form fields")
(assert (= "say" ((wshtmx/headers envelope) :HX-Trigger))
        "and they are there for the handler that wants to know which element fired")
(assert (nil? (wshtmx/fields {:type :text :data "not json at all"}))
        "a payload that is not the envelope is ignored, not raised")

(assert (= "ws" ((wshtmx/connect-attrs "/live") "hx-ext")))
(assert (= "/live" ((wshtmx/connect-attrs "/live") "ws-connect")))
(assert (= "true" ((wshtmx/send-attrs) "ws-send")))

# -- and now over the wire ------------------------------------------------

(defn chat [req]
  (ws/accept req
    {:rooms [:room]
     :on-message
     (fn [conn msg]
       (def fields (wshtmx/fields msg))
       (when fields
         (wshtmx/broadcast! :room
                            [:div {:id "messages" :hx-swap-oob "beforeend"}
                             [:p (fields :message)]])))}))

(def app-routes
  (router/routes {}
    (router/GET "/chat" 'chat {:name :chat :void.ws/socket true})))

(def app
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/ws-htmx ">=0.0.1"}
    :contributes {:void.http/route-source
                  [{:name :test/app :routes app-routes
                    :env (router/env-ref (curenv))}]}))

(def boot
  (test/start! {:plugins [:void/http :void/html :void/htmx :void/ws :void/ws-htmx app]
                :config {:env @{}
                         :cli {:log {:level :error}
                               :http {:port 0 :strict-meta true}}}}))

(def port (get-in boot [:system :instances :http/server :server :port]))

(defer (test/stop! boot 3)
  (def a (wsc/connect (string "ws://127.0.0.1:" port "/chat")))
  (def b (wsc/connect (string "ws://127.0.0.1:" port "/chat")))

  # exactly what htmx's ws-send puts on the wire for a one-field form
  (wsc/send! a (json/encode {"message" "good evening"
                             "HEADERS" {"HX-Request" "true"}}))

  (each peer [a b]
    (assert (= (string "<div id=\"messages\" hx-swap-oob=\"beforeend\">"
                       "<p>good evening</p></div>")
               ((wsc/receive peer) :data))
            "every peer in the room got the same swappable fragment"))

  (wsc/close! a)
  (wsc/close! b))

(print "htmx ok")
