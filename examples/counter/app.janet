### counter/app — the wave-5 example: the Biff idiom on void/datastar.
### One view function renders the whole page; every action handler returns
### that same page, and the plugin answers a Datastar client with the two
### morph events (<title> + <body>) instead of the document. The live
### half: the page opens /live on mount, the stream parks in the :counter
### room, and every mutation poke!s the room — each open tab re-renders
### its own view and converges on the count. "What exactly changed" is a
### question no code here answers.
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/html :as html)
(import void/datastar :as datastar)
(import void/datastar/ds :as ds)

# -- state (in-memory; one process — see README on replicas) -------------

(def state @{:n 0})

# -- views (plain functions returning hiccup) ----------------------------

(defn layout [content context]
  (html/html5
    [:head
     [:meta {:charset "utf-8"}]
     # the <title> is state too — the morph patches it by selector,
     # the one piece of a document id-matching cannot reach
     [:title (string "counter — " (state :n))]
     # datastar.js is an asset of the application, not the plugin, the
     # same way guestbook brings its own htmx
     [:script {:type "module"
               :src "https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.0-RC.7/bundles/datastar.js"}]]
    [:body content]))

(defn counter-view
  "The page: signals declare the step, data-on:load opens the live
  stream, and the buttons post to handlers that return this same view."
  []
  [:main (merge {:id "counter"}
                (ds/signals {:by 1})
                (ds/load (ds/action :get "/live" {:open-when-hidden true})))
   [:h1 {:id "count"} (string "count: " (state :n))]
   [:p
    [:button (ds/on :click (ds/action :post "/dec")) "−"]
    [:input (merge {:type "number"} (ds/bind "by"))]
    [:button (ds/on :click (ds/action :post "/inc")) "+"]]
   [:p {:class "hint"}
    "Open this page in two windows — every tab converges."]])

# -- handlers ------------------------------------------------------------

(defn- page []
  (html/page (counter-view) {:layout layout}))

(defn- step-of
  "The :by signal Datastar sent with the action, as a number; a page
  without signals (a plain request) steps by 1."
  [sig]
  (def by (get (or sig {}) :by 1))
  (def n (if (bytes? by) (scan-number (string by)) by))
  (if (number? n) n 1))

(defn- add! [d]
  (put state :n (+ (state :n) d))
  # wake every live stream: each re-renders its own page
  (datastar/poke! :counter))

(defn home
  "GET / — the full page; a Datastar request on the same route gets it
  as morph events (:void.datastar/morph on the route)."
  [req]
  (page))

(defn inc-count
  "POST /inc — mutate, poke the room, return the same page."
  [req]
  (add! (step-of (datastar/signals req)))
  (page))

(defn dec-count
  "POST /dec — the mirror of /inc."
  [req]
  (add! (- (step-of (datastar/signals req))))
  (page))

(defn live
  "GET /live — the long-lived side: the stream re-renders the full
  page on every poke! and pushes the same two morph events."
  [req]
  (datastar/morph-stream req (fn [] (layout (counter-view) {}))
                         {:rooms [:counter]}))

# -- routes --------------------------------------------------------------

(router/defroutes :counter/routes
  (GET "/" home {:void.datastar/morph true})
  (POST "/inc" inc-count {:name :counter/inc :void.datastar/morph true})
  (POST "/dec" dec-count {:name :counter/dec :void.datastar/morph true})
  (GET "/live" live {:name :counter/live}))

(plugin/defplugin counter/app
  :doc "counter application plugin — the Biff idiom."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/datastar ">=0.0.1"})
