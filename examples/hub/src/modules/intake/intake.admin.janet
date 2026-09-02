### intake/admin — deliveries, at a desk.
###
### **A projection, not a page.** `defentity` in ./intake.model already
### says what a delivery is, so the declaration below adds only what a
### schema cannot: which columns an operator scans, which they search
### by, which they filter on (ADR-0029). The one thing that is genuinely
### this application's is what to do with `body-key` — a column holding
### a storage key, which nobody wants to read and everybody wants to
### *open*.
###
### **The raw body goes out over a signed URL.** The bytes are the
### evidence (ADR-0039 §5, ./intake.service's whole argument), and they
### are also somebody else's payload: a repository name, a commit
### message, the address of a private branch. So `[:storage :serve
### :signed]` is `true` in this application — the whole prefix is
### private — and the link on the page carries `exp`/`sig` minted from
### void/security's keys, good for five minutes. The link is the
### authorization, which is why it is short-lived: a URL pasted into a
### chat must stop working before the chat is read.
###
### Who may open the page at all is ../auth/auth.policy.janet.
(import void/admin :as admin)
(import void/admin/widget :as admin-widget)
(import void/storage)
(import ./intake.model :as model)

(def link-ttl
  ``How long a raw-body link is good for, in seconds. Five minutes is
  "long enough to click, short enough that the URL in the scrollback is
  already dead" — the link *is* the authorization, so its lifetime is
  the whole of how far it travels.``
  300)

(def raw-body
  ``The widget that draws `body-key`. The column holds a storage key;
  what an operator wants is the bytes, so the cell is a link that
  `void/storage` signed (the CSRF construction on the same keys) and
  `void/storage-http` — or, with a bucket behind the contract, S3's own
  query auth — will verify.

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
         # a composition that keeps the bytes and serves them to nobody;
         # showing the key is the honest cell
         [:code (string key)])))
   :render
   (fn raw-body-render [ctx]
     [:code (or (ctx :value) "—")])})

(admin/defresource-admin deliveries model/Delivery
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
