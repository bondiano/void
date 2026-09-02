### hub/admin — the operator's half, and the only screen this
### application has.
###
### A hub is not a site with a back office bolted on: receiving is a
### machine talking to a machine, and everything a *person* does here
### is operations. So the guestbook `void new` wrote is gone, `/` is a
### redirect to the queue, and the two pages an incident needs are the
### two pages that exist.
###
### **The jobs dashboard is the main screen.** 6.3 built it for the
### case where somebody goes looking; here it is the front door,
### because the question this application is asked at three in the
### morning is "did it go out" — and that is a question about the
### queue. Nothing was written to make it so: `void/admin-jobs`
### contributes the page, `void/http` reverse-routes its name, and the
### home handler is one line.
###
### **The deliveries page is a projection, not a page.** `defentity`
### in ./intake already says what a delivery is, so the declaration
### below adds only what a schema cannot: which columns an operator
### scans, which they search by, which they filter on (ADR-0029). The
### one thing that is genuinely this application's is what to do with
### `body-key` — a column holding a storage key, which nobody wants to
### read and everybody wants to *open*.
###
### **The raw body goes out over a signed URL.** The bytes are the
### evidence (ADR-0039 §5, ./intake's whole argument), and they are
### also somebody else's payload: a repository name, a commit message,
### the address of a private branch. So `[:storage :serve :signed]` is
### `true` in this application — the whole prefix is private — and the
### link on the page carries `exp`/`sig` minted from void/security's
### keys, good for five minutes. The link is the authorization, which
### is why it is short-lived: a URL pasted into a chat must stop
### working before the chat is read.
###
### **Who is an operator is a list, not a table.** `[:hub :operators]`
### is the addresses that may come in. A hub has one or two of them,
### a column on `users` would need a migration and a page to edit it,
### and a list in config is a thing a deployment already knows how to
### set (`VOID_HUB__OPERATORS='["ada@example.com"]'`). The list is
### empty by default, which means the desk is shut by default —
### registration on this application is open, and an open registration
### plus "anybody signed in is staff" is a hub anybody can read.
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/admin :as admin)
(import void/admin/widget :as admin-widget)
(import void/authz :as authz)
(import void/http)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/storage)
(import ./intake)

(def log-ns "hub.admin")

# -- who may come in -----------------------------------------------------

(var- operators
  "The addresses `[:hub :operators]` names, read once at start."
  [])

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 410
   :name :hub/operators
   :doc "Resolve [:hub :operators] — the addresses the desk lets in"
   :fn (fn configure [boot]
         (set operators (or (get-in boot [:config :values :hub :operators]) []))
         # the count, not the addresses: a log line is the one place a
         # list of who has access should not be
         (log/info "operators ready" :ns log-ns :operators (length operators)))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 140
   :name :hub/warn-when-nobody
   :doc "Say at start that the desk lets nobody in, rather than at the first 403"
   :fn (fn warn [_boot]
         (when (empty? operators)
           (log/warn (string "the desk refuses everybody: [:hub :operators] names "
                             "no address. Set it to the addresses that may read "
                             "deliveries — VOID_HUB__OPERATORS='[\"you@example.com\"]'")
                     :ns log-ns)))})

(authz/defpolicy :hub/operator
  ``The gate `[:admin :access]` names. The identity carries the address
  as a claim (`[:auth-db :users :claims-columns]`), so this decision
  costs no query — which is what `attr` is for (ADR-0024 §2).

  Both refusals are sentences rather than `false`, because a policy
  that says why is a policy an operator can act on: `void authz explain`
  prints exactly this string.``
  [ctx]
  (def email (authz/attr ctx :subject/email))
  (cond
    (nil? email) "not signed in"
    (index-of email operators) true
    "not an operator of this hub — [:hub :operators] does not name this address"))

# -- the raw body, behind a link that expires ----------------------------

(def link-ttl
  ``How long a raw-body link is good for, in seconds. Five minutes is
  "long enough to click, short enough that the URL in the scrollback
  is already dead" — the link *is* the authorization, so its lifetime
  is the whole of how far it travels.``
  300)

(def raw-body
  ``The widget that draws `body-key`. The column holds a storage key;
  what an operator wants is the bytes, so the cell is a link that
  `void/storage` signed (./sign — the CSRF construction on the same
  keys) and `void/storage-http` will verify.

  `:render` is here because the contract requires it and for no other
  reason: this resource has no form, and a key is not a thing anybody
  types.``
  {:name :hub/raw-body
   :doc "the delivery's own bytes, behind a temporary URL"
   :display
   (fn raw-body-display [ctx]
     (def key (ctx :value))
     (if (nil? key)
       (admin-widget/text-of nil)
       (if-let [url (storage/url (string key) {:expires link-ttl})]
         [:a {:href url :target "_blank" :rel "noreferrer" :title (string key)}
          "raw body"]
         # a composition without void/storage-http keeps the bytes and
         # serves them to nobody; showing the key is the honest cell
         [:code (string key)])))
   :render
   (fn raw-body-render [ctx]
     [:code (or (ctx :value) "—")])})

# -- the deliveries page -------------------------------------------------

(admin/defresource-admin deliveries intake/Delivery
  :title "Deliveries"
  :singular "Delivery"
  :doc "Everything this hub received, newest first — and the bytes it received."
  # read-only, and not because a write would be hard: a received
  # delivery is a fact about the past, and a fact somebody can edit
  # from the page that displays it is not evidence
  :only [:index :show]
  :list [:id :received-at :source :event :repo :sender :size :body-key]
  :detail [:id :delivery-id :received-at :source :event :repo :sender
           :size :body-key]
  # what an operator has in their hand when they come looking: the id
  # GitHub showed them, or the repository somebody is asking about
  :search [:delivery-id :repo :sender]
  :filters [:source :event]
  :sortable [:id :received-at :size]
  :order-by [[:id :desc]]
  :widgets {:body-key raw-body})

# -- the front door ------------------------------------------------------

(defn home
  ``GET / — the queue.

  The target is reverse-routed from the name `void/admin-jobs`'
  page carries rather than written out: `[:admin :prefix]` is config,
  and a string here would be a second place to change it (ADR-0029 §2
  — every action is a real route, so every route has a name).``
  [_req]
  (ring/redirect (http/url-for :admin.page/jobs)))

(router/defroutes :hub/admin-routes
  (GET "/" home {:name :hub/home :void.auth/access :public}))

(plugin/defplugin hub/admin
  :doc "The operator's half: the jobs dashboard as the front door, deliveries as an admin resource, and the raw body of each one behind a signed URL that expires."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/admin ">=0.0.1"
             :void/admin-jobs ">=0.0.1" :void/authz ">=0.0.1"
             :void/storage ">=0.0.1"})
