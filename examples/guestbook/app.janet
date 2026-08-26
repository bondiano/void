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
  "A guestbook entry — drives both form/check and form/form."
  {:name [:string {:min 1 :max 40}]
   :message [:string {:min 1 :max 400}]})

# -- state (in-memory until void/db lands in your :plugins) --------------

(def entries @[])

# -- views (plain functions returning hiccup) ----------------------------

(defn layout [content context]
  (html/html5
    [:head
     [:meta {:charset "utf-8"}]
     [:title "guestbook"]
     [:script {:src "https://unpkg.com/htmx.org@2.0.7"}]]
    [:body [:main content]]))

(defn guestbook-view
  "The #guestbook fragment: schema-driven form plus the entries list.
  On an invalid submission the caller passes the raw values and the
  schema errors back in and the same markup re-renders annotated."
  [&opt values errors]
  [:div {:id "guestbook"}
   [:h1 "guestbook guestbook"]
   (form/form Entry
     {:action "/entries"
      :values values
      :errors errors
      :fields {:message {:control :textarea}}
      :submit "Sign"
      :attrs (hx/post "/entries" :target "#guestbook" :swap :outer-html)})
   [:ul {:class "entries"}
    (if (empty? entries)
      [:li {:class "empty"} "No entries yet — sign the book."]
      (seq [e :in (reverse entries)]
        [:li [:strong (e :name)] ": " (e :message)]))]])

# -- handlers ------------------------------------------------------------

(defn home
  "GET / — the full page."
  [req]
  (html/page (guestbook-view) {:layout layout}))

(defn create-entry
  "POST /entries — form/check validates and coerces against Entry;
  invalid input re-renders the fragment with per-field errors."
  [req]
  (def result (form/check Entry (req :form)))
  (if (empty? (result :errors))
    (do
      (array/push entries (result :value))
      (html/page (guestbook-view) {:layout layout}))
    (html/page (guestbook-view (req :form) (result :errors))
               {:layout layout})))

# -- routes --------------------------------------------------------------

(plugin/defcontribution :void.http/route-source
  {:name :guestbook/routes
   :routes (router/routes {}
             (router/GET "/" 'home {:name :home})
             # :void.htmx/partial — an HX-Request gets the bare
             # fragment; a plain form POST still gets the full page
             (router/POST "/entries" 'create-entry
                          {:name :entries/create
                           :void.htmx/partial true}))
   :env (router/env-ref (curenv))})

(plugin/defplugin guestbook/app
  :doc "guestbook application plugin."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"})