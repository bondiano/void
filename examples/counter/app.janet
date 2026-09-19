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

(defn layout
  {:params [:any :any] :ret @[:any]}
  "Wrap `content` in the page shell: head, stylesheet, datastar script."
  [content context]
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     # the <title> is state too — the morph patches it by selector,
     # the one piece of a document id-matching cannot reach
     [:title (string "counter — " (state :n))]
     # the compiled stylesheet: the logical name in development, the
     # fingerprinted one after `void assets build` — the markup does
     # not know which (config/default.janet)
     [:link {:rel "stylesheet" :href (html/asset "app.css")}]
     # the layout is the application's, so loading datastar.js is its
     # decision — the plugin supplies the pinned tag with its
     # integrity hash, the way admin and dash carry htmx's
     (datastar/script-tag)]
    [:body {:class "min-h-dvh bg-slate-950 text-slate-100 antialiased selection:bg-indigo-500/40"}
     content]))

(def button-class
  "The two step buttons are one button — a second copy of this string is
  how they start disagreeing."
  (string "grid h-14 w-14 place-items-center rounded-2xl border border-white/10 "
          "bg-white/5 text-3xl font-light text-white transition "
          "hover:border-indigo-400/50 hover:bg-indigo-500/20 "
          "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-400 "
          "active:scale-95"))

(defn counter-view
  {:params [] :ret :tuple}
  "The page: signals declare the step, data-init opens the live
  stream, and the buttons post to handlers that return this same view."
  []
  (def n (state :n))
  [:main (merge {:id "counter"
                 :class "relative isolate grid min-h-dvh place-items-center overflow-hidden px-6 py-16"}
                (ds/signals {:by 1})
                (ds/load (ds/action :get "/live" {:open-when-hidden true})))
   # the glow behind the card: one radial gradient, no image and no
   # element anything else has to reason about
   [:div {:aria-hidden "true"
          :class "pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(60rem_40rem_at_50%_-10%,rgb(79_70_229/0.28),transparent)]"}]
   [:div {:class "w-full max-w-md rounded-3xl border border-white/10 bg-white/5 p-10 text-center shadow-2xl shadow-indigo-950/60 backdrop-blur-xl"}
    [:p {:class "text-xs font-semibold uppercase tracking-[0.3em] text-indigo-300/80"}
     "void · datastar"]
    [:h1 {:id "count" :data-count (string n)
          :class "mt-8 font-mono text-8xl font-bold tabular-nums leading-none text-white drop-shadow-[0_0_2.5rem_rgb(99_102_241/0.55)]"}
     (string n)]
    [:div {:class "mt-10 flex items-center justify-center gap-3"}
     [:button (merge (ds/on :click (ds/action :post "/dec"))
                     {:type "button" :aria-label "decrement"
                      :class button-class})
      "−"]
     [:input (merge {:type "number" :aria-label "step"
                     :class "h-14 w-20 rounded-2xl border border-white/10 bg-slate-900/80 text-center font-mono text-lg tabular-nums text-white outline-none transition focus:border-indigo-400 focus:ring-2 focus:ring-indigo-500/40"}
                    (ds/bind "by"))]
     [:button (merge (ds/on :click (ds/action :post "/inc"))
                     {:type "button" :aria-label "increment"
                      :class button-class})
      "+"]]
    [:p {:class "mt-8 text-sm leading-relaxed text-slate-400"}
     "Open this page in two windows — every tab converges."]]])

# -- handlers ------------------------------------------------------------

(defn- page
  {:params []
   :ret HtmlView
   :throws [:string]}
  "Render the current count through the shared layout."
  []
  (html/page (counter-view) {:layout layout}))

(defn- step-of
  {:params [(or {:keyword :any} :nil)] :ret :number}
  "The :by signal Datastar sent with the action, as a number; a page
  without signals (a plain request) steps by 1."
  [sig]
  (def by (get (or sig {}) :by 1))
  (def n (if (bytes? by) (scan-number (string by)) by))
  (if (number? n) n 1))

(defn- add!
  {:params [:number] :ret :nil}
  "Apply a delta to the shared count and wake every live stream so
  each tab re-renders and converges."
  [d]
  (put state :n (+ (state :n) d))
  # wake every live stream: each re-renders its own page
  (datastar/poke! :counter))

(defn home
  {:params [:any]
   :ret HtmlView
   :throws [:string]}
  "GET / — the full page; a Datastar request on the same route gets it
  as morph events (:void.datastar/morph on the route)."
  [req]
  (page))

(defn inc-count
  {:params [{:method :keyword :query {:string :any} :body :any & r}]
   :ret HtmlView
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "POST /inc — mutate, poke the room, return the same page."
  [req]
  (add! (step-of (datastar/signals req)))
  (page))

(defn dec-count
  {:params [{:method :keyword :query {:string :any} :body :any & r}]
   :ret HtmlView
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "POST /dec — the mirror of /inc."
  [req]
  (add! (- (step-of (datastar/signals req))))
  (page))

(defn live
  {:params [:any] :ret HttpResponseTable}
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
