### guestbook/app — the application plugin: schema, views, routes.
### Handlers are registered as symbols (late binding): redefine one in
### the repl — or save this file with the watcher running — and the
### running app picks it up; route and metadata edits rebuild the
### table on the fly.
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx/hx :as hx)

# -- schema: one source of truth for validation and form markup ----------

(def Entry
  "A guestbook entry — drives both form/submit and form/form."
  {:name [:string {:min 1 :max 40}]
   :message [:string {:min 1 :max 400}]})

# -- state (in-memory until void/db lands in your :plugins) --------------

(def entries @[])

# -- views (plain functions returning hiccup) ----------------------------

(defn layout
  {:params [:any :any] :ret @[:any]}
  "Wrap `content` in the page shell: head, stylesheet, htmx script."
  [content context]
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "guestbook"]
     # the compiled stylesheet: the logical name in development, the
     # fingerprinted one after `void assets build` — the markup does
     # not know which (config/default.janet)
     [:link {:rel "stylesheet" :href (html/asset "app.css")}]
     [:script {:src "https://unpkg.com/htmx.org@4.0.0"}]]
    [:body {:class "min-h-dvh bg-paper text-ink antialiased"}
     [:main {:class "mx-auto max-w-2xl px-6 py-16"} content]]))

(defn guestbook-view
  {:params [(or {:any :any} :nil) (or [{:path :any & r}] :nil)] :ret :tuple}
  "The #guestbook fragment: schema-driven form plus the entries list.
  On an invalid submission the caller passes the raw values and the
  schema errors back in and the same markup re-renders annotated."
  [&opt values errors]
  [:div {:id "guestbook"}
   [:header {:class "mb-10"}
    [:p {:class "text-xs font-semibold uppercase tracking-[0.25em] text-amber-700/70"}
     "a void example"]
    [:h1 {:class "mt-3 text-4xl font-bold tracking-tight"} "Guestbook"]
    [:p {:class "mt-2 text-ink/60"}
     "Leave a line. The form below is a projection of the schema above it."]]
   [:div {:class "rounded-2xl border border-ink/10 bg-white p-6 shadow-sm shadow-ink/5"}
    (form/form Entry
      {:action "/entries"
       :values values
       :errors errors
       :fields {:message {:control :textarea}}
       :submit "Sign"
       # `form/form` writes the fields; this says how they stack, and
       # styles/app.css says what one looks like
       :attrs (merge {:class "flex flex-col gap-5"}
                     (hx/post "/entries" :target "#guestbook" :swap :outer-html))})]
   [:ul {:class "mt-10 flex list-none flex-col gap-3 p-0"}
    (if (empty? entries)
      [:li {:class "rounded-2xl border border-dashed border-ink/15 px-5 py-10 text-center text-ink/45"}
       "No entries yet — sign the book."]
      (seq [e :in (reverse entries)]
        [:li {:class "rounded-2xl border border-ink/10 bg-white px-5 py-4 shadow-sm shadow-ink/5"}
         [:p {:class "text-sm font-semibold text-amber-800"} (e :name)]
         [:p {:class "mt-1 whitespace-pre-line leading-relaxed text-ink/80"} (e :message)]]))]])

# -- handlers ------------------------------------------------------------

(defn home
  {:params [:any]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "GET / — the full page."
  [req]
  (html/page (guestbook-view) {:layout layout}))

(defn create-entry
  {:params [{:form :any & r}] :ret :any :throws [:string]}
  ``POST /entries — form/submit checks Entry and picks one of two
  continuations: a valid one appends and re-renders the fragment, an
  invalid one re-renders it with the raw values and the per-field
  errors — as a 422, which htmx swaps like any other status.``
  [req]
  (form/submit Entry (req :form)
    {:ok (fn [v]
           (array/push entries v)
           (html/page (guestbook-view) {:layout layout}))
     :invalid (fn [values errors]
                (html/page (guestbook-view values errors) {:layout layout}))}))

# -- routes --------------------------------------------------------------

# defroutes writes the :void.http/route-source contribution: handler
# symbols are quoted for you (late binding) and name their route.
(router/defroutes :guestbook/routes
  (GET "/" home)
  # :void.htmx/partial — a swap into an element (HX-Request-Type:
  # partial) gets the bare fragment; a plain form POST still gets the
  # full page
  (POST "/entries" create-entry
        {:name :entries/create :void.htmx/partial true}))

(plugin/defplugin guestbook/app
  :doc "guestbook application plugin."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"})