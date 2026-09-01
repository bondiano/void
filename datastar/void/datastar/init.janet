### void/datastar — Datastar integration plugin, an experiment
### (SPEC §5.5, ADR-0037).
###
### The Biff idiom, standing on what the repository already has: a
### handler keeps returning the full page it always returned, and the
### plugin turns that page into the two SSE events Datastar morphs the
### live DOM with — the <title> by selector, the <body> by selector —
### so an action re-renders everything and the browser keeps focus,
### scroll and input state. The middleware that does it sits at phase
### 8500, *shallower* than void/html's render (9000): the chain
### unwinds innermost-first, so by the time the response reaches this
### plugin the page is bytes, and slicing <title> and <body> out of
### them is two string searches — no second render, no HTML parser.
### It is the mirror of void/htmx's partial middleware (9500), which
### needs the response *before* the engine runs to strip the layout;
### this one needs it after, to reuse the render.
###
### The live half is the same idiom pushed through time: morph-stream
### parks a connection on a channel, poke! wakes every member of a
### room, and each connection re-renders *its own* page (identity,
### locale and the rest live in dyns the stream fiber inherited) and
### pushes the same two events. Fan-out across replicas is a void/bus
### subscriber that pokes locally — the pose ADR-0028 struck for
### websocket rooms, and the registry answers the fleet check the same
### way (:shared? :by-design).

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/http/ring :as ring)
(import void/html/hiccup :as hiccup)
(import ./proto :as proto)

# -- request side --------------------------------------------------------

(defn request?
  "Did Datastar issue this request (Datastar-Request: true)?"
  [req]
  (= "true" (ring/request-header req "datastar-request")))

(defn signals
  ``The signals Datastar sent with the request: the `datastar` query
  parameter on a GET, the JSON body otherwise (keyword keys, the way
  every other decoded body in void arrives). nil when the request
  carries none; malformed JSON is a 400, not a handler crash.``
  [req]
  (def raw
    (if (= :get (req :method))
      (get-in req [:query "datastar"])
      (let [b (req :body)]
        (when (and b (not (empty? b))) (string b)))))
  (when raw
    (def [ok v] (protect (json/decode (string raw) true)))
    (unless (and ok (dictionary? v))
      (error {:http/status 400 :message "malformed datastar signals"}))
    v))

# -- rendering and events ------------------------------------------------

(defn- render-content [content]
  (if (bytes? content)
    (string content)
    (hiccup/render-string content)))

(defn patch-elements
  "proto/patch-elements over hiccup: content renders through the
  hiccup pipeline, a string or buffer passes through untouched."
  [content &opt opts]
  (proto/patch-elements
    (if (nil? content) nil (render-content content))
    opts))

(def patch-signals "See proto/patch-signals." proto/patch-signals)
(def remove-elements "See proto/remove-elements." proto/remove-elements)

(defn events
  ``An SSE response of Datastar events — the builders here already
  return what ring/sse-event frames, so this is ring/sse with the
  vocabulary attached:

      (datastar/events [(datastar/patch-signals {:count 2})])``
  [evs &opt headers]
  (ring/sse evs headers))

(defn- slice-tag [html tag]
  # "<tag ...>...</tag>" inclusive, or nil. Enough HTML awareness for
  # a page this plugin's own render produced; a page that puts
  # "<body" inside a comment before its body element deserves what it
  # gets (named in ADR-0037).
  (def open-at (string/find (string "<" tag) html))
  (def close-tag (string "</" tag ">"))
  (def close-at (string/find close-tag html))
  (when (and open-at close-at (< open-at close-at)
             (let [c (get html (+ 1 open-at (length tag)))]
               (or (= c (chr ">")) (= c (chr " ")) (= c (chr "\n")) (= c (chr "\t")))))
    (string/slice html open-at (+ close-at (length close-tag)))))

(defn page-events
  ``A rendered page as the events that morph it in place: the <title>
  and the <body>, each patched by selector — the only two pieces of a
  document Datastar's id-matching cannot reach. Markup without a
  <body> (a fragment) becomes a single patch-elements event morphing
  by id, so the same route metadata serves fragment handlers too.``
  [html]
  (def page (string html))
  (if-let [body (slice-tag page "body")]
    (do
      (def out @[])
      (when-let [title (slice-tag page "title")]
        (array/push out (proto/patch-elements title {:selector "title"})))
      (array/push out (proto/patch-elements body {:selector "body"}))
      out)
    @[(proto/patch-elements page)]))

# -- the morph middleware ------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.datastar/morph
   :schema :boolean
   :doc "Answer a Datastar request with the rendered page as morph events (title + body over SSE) instead of an HTML document"
   :merge :replace})

(defn- html-response? [resp]
  (and (dictionary? resp)
       (bytes? (get resp :body))
       (let [ct (get-in resp [:headers "content-type"])]
         (and ct (string/has-prefix? "text/html" ct)))))

(plugin/contribute! :void.http/middleware
  {:name :void.datastar/morph
   :phase 8500
   :doc "Turn the rendered page into Datastar morph events on routes marked :void.datastar/morph — shallower than the render middleware, so the page is already bytes"
   :when |(get $ :void.datastar/morph)
   :wrap (fn [handler]
           (fn datastar-morph [req]
             (def resp (handler req))
             (if (and (request? req) (html-response? resp))
               @{:status (resp :status)
                 :headers (merge @{}
                                 (resp :headers)
                                 @{"content-type" "text/event-stream"
                                   "cache-control" "no-cache"})
                 :body (map ring/sse-event (page-events (resp :body)))}
               resp)))})

# -- the live half: streams, rooms, poke! --------------------------------

(var current-registry
  "The registry of the running :datastar/registry component — one per
  process, like plugin/current-boot."
  nil)

(defn- registry []
  (or current-registry
      (error "void/datastar is not started — add :void/datastar to :plugins (the :datastar/registry component holds the streams)")))

(defn- join! [reg rooms conn]
  (each r rooms (put-in reg [:rooms r conn] true)))

(defn- leave! [reg rooms conn]
  (each r rooms
    (when-let [members (get-in reg [:rooms r])]
      (put members conn nil)
      (when (empty? members)
        (put (reg :rooms) r nil)))))

(defn poke!
  ``Wake every stream in the named rooms: each re-renders its own view
  and pushes the morph. A member whose wake-up is already pending is
  skipped — two pokes before a render still mean one render, which is
  the point of re-rendering the whole page instead of diffing.``
  [& rooms]
  (def reg (registry))
  (each r rooms
    (eachk conn (or (get-in reg [:rooms r]) {})
      (def ch (conn :chan))
      (when (< (ev/count ch) (ev/capacity ch))
        (ev/give ch :poke)))))

(defn morph-stream
  ``The long-lived side of the idiom — a route the page opens with
  (ds/load (ds/action :get "/live")):

      (defn live [req]
        (datastar/morph-stream req (fn [] (orders-page req))
                               {:rooms [:orders]}))

  `view` re-renders the full page (hiccup or ready markup) each time
  poke! names one of the stream's :rooms; the connection pushes the
  morph events page-events cuts from it. :initial true (the default)
  pushes one morph on connect — the reconnect after a dropped SSE
  connection resynchronizes a page that went stale while offline.``
  [req view &opt opts]
  (default opts {})
  (def reg (registry))
  (def rooms (get opts :rooms []))
  (def conn @{:chan (ev/chan 1)})
  (ring/sse
    (coro
      (join! reg rooms conn)
      (defer (leave! reg rooms conn)
        (when (get opts :initial true)
          (each e (page-events (render-content (view))) (yield e)))
        (forever
          (match (ev/take (conn :chan))
            nil (break)                      # the registry stopped
            (each e (page-events (render-content (view))) (yield e))))))))

# -- the component -------------------------------------------------------

(def registry-component
  (system/component :datastar/registry
    :doc "Every live morph-stream this process holds and the rooms it
    listens to. Depends on :http/server so a drain closes the streams
    before the listener goes: stopping runs in reverse dependency
    order."
    :deps [:http/server]
    :start
    (fn start [_ _]
      (def reg @{:rooms @{}})
      (set current-registry reg)
      reg)
    :stop
    (fn stop [reg]
      # closing a channel wakes its taker with nil — every stream
      # fiber breaks out and unregisters itself
      (each members (values (reg :rooms))
        (eachk conn members
          (ev/chan-close (conn :chan))))
      (set current-registry nil)
      reg)
    :health
    (fn health [reg]
      {:status :up
       :rooms (length (reg :rooms))
       :streams (sum (map length (values (reg :rooms))))})))

(plugin/contribute! :void.core/store
  {:name :void.datastar/streams
   :what "datastar morph streams"
   :needs [:datastar/registry]
   :doc "The stream registry is per process, and that is the design (ADR-0037, the pose of ADR-0028) — not something a fleet check should ask anyone to fix"
   :ask (fn ask-streams [boot]
          (when (get-in boot [:system :instances :datastar/registry])
            {:store :process
             :shared? :by-design
             :why "an SSE connection lives in the process holding its socket, so a registry that spanned processes could not reach it anyway; fan-out across replicas is a void/bus subscriber that pokes locally (ADR-0028's pose)"}))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/datastar
  :doc "Datastar integration (experimental): data-* attribute builders, signal reading, patch-elements/patch-signals SSE events, and the Biff idiom — routes marked :void.datastar/morph answer a Datastar request with the rendered page as morph events (title + body), and morph-stream keeps a page live, re-rendering on poke!."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1" :void/html ">=0.0.1"}
  :components [registry-component])
