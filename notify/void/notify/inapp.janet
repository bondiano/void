### void/notify-inapp — the bell.
###
### The channel that delivers into the application itself: a row in the
### one table void owns here (./store) and four ordinary routes that
### draw it. No new machinery — the panel is a `html/fragment`, the
### bell is an `hx-get` that polls, and marking one read is an
### `hx-post` that answers with the panel again.
###
###     ; in the layout, once
###     (inapp/bell)
###
###     ; in a migration, once
###     (import void/notify/store :as notify-store)
###     (defn up [] (notify-store/tables))
###
### and every `notify/send` that carries `:to {:subject "user:42"}`
### shows up there.
###
### **The recipient is the identity in the dyn, never a parameter.**
### Every route here answers about `(dyn :void.auth/identity)` and every
### function in ./store takes the recipient as its first argument, so a
### listing keyed by somebody else's id is not a bug that can be written —
### there is no code path that would take one. The dyn is read by name
### rather than by importing `void/auth`, the way `void/authz` reads it:
### an application with its own authentication binds the same key and gets
### the same bell.
###
### **The views are vars**, the `void/mail-auth` pose: `badge-view` and
### `list-view` are replaced by assignment, and a single notification
### overrides its own row with an `:inapp` key. An extension point here
### would be a second way to do what a var already does.
###
### `[:notify-inapp :policy]` becomes the routes' `:void.authz/policy`,
### which is the line a composition under `[:authz :default :deny]`
### needs; without it such a composition refuses to start naming these
### routes, and that refusal is right — under a deny posture silence
### must not mean public.

(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/html :as html)
(import void/http/errors :as errors)
(import void/http/router :as router)
(import ./channel :as channel)
(import ./notification :as notification)
(import ./store :as store)

(require "void/notify/init")

(def log-ns "void.notify.inapp")

(def identity-dyn
  ``The dyn key `void/auth` publishes the current identity under, read
  by name rather than by importing the package.``
  :void.auth/identity)

(def Config
  "Schema of the [:notify-inapp] config slice."
  {:table [:optional :string]
   :prefix [:optional :string]
   :policy [:optional :keyword]
   :limit [:optional [:int {:min 1}]]
   :poll [:optional [:int {:min 1}]]})

(def defaults
  ``Defaults of the [:notify-inapp] slice.

  `:poll` is how often the bell asks for its own count, in seconds.
  Thirty is a compromise with a name: a notification that must be seen
  *now* is a websocket (`void/ws`), and one that can wait a minute
  should not cost a request a second.

  `:policy` has no default on purpose — see the header.``
  {:table "notifications"
   :prefix "/notifications"
   :policy nil
   :limit 25
   :poll 30})

(var settings
  "The [:notify-inapp] slice, resolved at :before-start."
  defaults)

(defn recipient
  "Who this fiber is, as the store spells a recipient — or nil for an
  anonymous visitor, which is what makes the bell absent rather than
  empty."
  []
  (when-let [id (dyn identity-dyn)]
    (get id :subject)))

(defn- prefix [] (get settings :prefix "/notifications"))
(defn badge-path "Where the bell polls." [] (string (prefix) "/badge"))

# -- the channel ---------------------------------------------------------

(defn project
  ``The row to write, or nil when the notification carries no subject
  to write it against. The `:inapp` override is merged here, so a
  notification can say a different title in the bell than in the
  letter.``
  [note]
  (when-let [to (notification/address-for note {:address :subject})]
    (merge note
           (notification/override-for note :inapp)
           {:recipient to})))

(defn deliver
  "Write the row."
  [payload]
  (store/record! payload (payload :recipient) settings)
  (channel/receipt :inapp payload {:recipient (payload :recipient)}))

(plugin/contribute! :void.notify/channel
  {:name :inapp
   :doc "Write the notification into the application's own table; the bell reads it back"
   :address :subject
   :project project
   :deliver deliver})

# -- the views -----------------------------------------------------------

(var badge-view
  ``The bell itself, as hiccup: a link that opens the panel and the
  count beside it. A var, so an application replaces it without a new
  extension point.``
  (fn notify-badge [n]
    [:a {:href (string (get settings :prefix "/notifications"))
         :hx-get (string (get settings :prefix "/notifications"))
         :hx-target "#void-notify-panel"
         :hx-swap "innerHTML"
         :class "void-notify-badge"
         :aria-label (string n " unread notifications")}
     "🔔"
     (when (pos? n)
       [:span {:class "void-notify-count"
               :style (string "margin-left: 4px; padding: 0 6px; border-radius: 9px; "
                              "background: #d33; color: #fff; font-size: 12px")}
        (string n)])]))

(var list-view
  "The panel: a recipient's notifications, newest first. A var, like
  `badge-view`."
  (fn notify-list [items]
    (def base (get settings :prefix "/notifications"))
    [:div {:class "void-notify-list"}
     (if (empty? items)
       [:p {:class "void-notify-empty"} "Nothing new."]
       [:ul {:style "list-style: none; margin: 0; padding: 0"}
        ;(seq [n :in items]
           [:li {:class (if (n :read?) "void-notify-read" "void-notify-unread")
                 :style "padding: 8px 0; border-bottom: 1px solid #eee"}
            (if-let [href (n :url)]
              [:a {:href href} (n :title)]
              [:strong (n :title)])
            (when-let [b (n :body)] [:p {:style "margin: 4px 0 0"} b])
            (unless (n :read?)
              [:button {:hx-post (string base "/" (n :id) "/read")
                        :hx-target "#void-notify-panel"
                        :hx-swap "innerHTML"
                        :style "margin-top: 4px"}
               "Mark read"])])])
     (when (some |(not ($ :read?)) items)
       [:button {:hx-post (string base "/read-all")
                 :hx-target "#void-notify-panel"
                 :hx-swap "innerHTML"}
        "Mark all read"])]))

(defn bell
  ``The one line a layout carries. Empty for an anonymous visitor —
  there is nobody to have notifications — and otherwise a container
  that fetches its own badge and holds the panel the badge opens.``
  []
  (when (recipient)
    [:span {:class "void-notify"}
     [:span {:id "void-notify-bell"
             :hx-get (badge-path)
             :hx-trigger (string "load, every " (get settings :poll 30) "s")
             :hx-swap "innerHTML"}]
     [:span {:id "void-notify-panel"}]]))

# -- the routes ----------------------------------------------------------

(defn- me []
  (or (recipient)
      # a bell asking about nobody is not a 404: the request was
      # understood and it needs a session
      (errors/abort 401 "notifications are personal — sign in first")))

(defn panel
  "GET the panel: the newest notifications, as a fragment."
  [req]
  (html/fragment (list-view (store/list-for (me)
                                            {:limit (get settings :limit 25)}
                                            settings))))

(defn badge
  "GET the bell's own count."
  [req]
  (html/fragment (badge-view (store/unread-count (me) settings))))

(defn mark-read
  "POST: mark one notification read and answer with the panel."
  [req]
  (def who (me))
  (store/mark-read! who (get-in req [:params :id] "") nil settings)
  (panel req))

(defn mark-all-read
  "POST: mark everything read and answer with the panel."
  [req]
  (def who (me))
  (def n (store/mark-all-read! who nil settings))
  (log/debug "notifications marked read" :ns log-ns :recipient who :rows n)
  (panel req))

(defn- own-routes
  # a function of boot, not a value: the mount prefix is configuration,
  # which is not known when this manifest freezes (the form)
  [_boot]
  (def base (prefix))
  (router/routes (if-let [policy (settings :policy)]
                   {:void.authz/policy policy}
                   {})
    (router/GET base 'panel {:name :void.notify/panel})
    (router/GET (string base "/badge") 'badge {:name :void.notify/badge})
    (router/POST (string base "/read-all") 'mark-all-read
                 {:name :void.notify/read-all})
    (router/POST (string base "/:id/read") 'mark-read
                 {:name :void.notify/read})))

# -- boot ----------------------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   # before the route table is built, the void/storage-http phase
   :phase 450
   :name :notify-inapp/configure
   :doc "Read the [:notify-inapp] slice once, before the route table is built"
   :fn (fn configure [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :notify-inapp]) {}))))})

(plugin/defplugin void/notify-inapp
  :doc "The in-app channel of void/notify: one row per notification in a table void owns (its DDL is data — put (notify-store/tables) in a migration) and an htmx bell that polls its own count. Every route answers about the identity in the dyn, never about a recipient in the request."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/notify ">=0.0.1"
             :void/db ">=0.0.1" :void/http ">=0.0.1" :void/html ">=0.0.1"}
  :config-key :notify-inapp
  :config-schema Config
  :config-defaults defaults
  :contributes {:void.http/route-source
                [{:name :void/notify-inapp
                  :routes own-routes
                  :env (router/env-ref (curenv))}]})
