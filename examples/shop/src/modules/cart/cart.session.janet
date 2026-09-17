### shop/cart/session — the one place that knows where a browser keeps
### its cart.
###
### A thin adapter between a request and ./cart.service, and the reason
### it is a file rather than three lines in the controller: the page
### frame needs it too (src/web/layout.janet draws the badge), and a
### session key spelled in two places is a session key that will be
### spelled differently in one of them.
###
### Everything below is `req -> cart`. Nothing below decides anything.
(import ./cart.service :as service)

(def session-key
  "Where the browser keeps its handle on its cart."
  :cart)

(defn token-of
  {:params [@{:session @{:keyword :any} & r}] :ret :string?}
  "The cart token this request carries, or nil."
  [req]
  (get (req :session) session-key))

(defn current
  {:params [@{:session @{:keyword :any} & r}]
   :ret (or @{:id :number :token :string :customer-id :number? :created-at :string
             :updated-at :string & r} :nil)
   :throws [:string]}
  "The cart this request is holding, or nil."
  [req]
  (service/find-by-token (token-of req)))

(defn ensure!
  {:params [@{:session @{:keyword :any} & r}]
   :ret @{:id :number :token :string :customer-id :number? :created-at :string
         :updated-at :string & r}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  ``The cart this request is holding, created if there is none. Called
  by the one handler that is about to put something in it.``
  [req]
  (or (current req)
      (let [{:cart cart :token token} (service/open!)]
        (put (req :session) session-key token)
        cart)))

(defn forget!
  {:params [@{:session @{:keyword :any} & r}] :ret :nil}
  ``Drop the cart from this session. The row is gone (the checkout
  deleted it) and a session pointing at a token that no longer exists
  would make the next `ensure!` create a second one.``
  [req]
  (put (req :session) session-key nil))

(defn adopt!
  {:params [@{:session @{:keyword :any} & r} :number]
   :ret :number?
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Attach the cart in hand to whoever just signed in."
  [req customer-id]
  (service/adopt! (current req) customer-id))

(defn item-count
  {:params [@{:session @{:keyword :any} & r}] :ret :number :throws [:string]}
  "What the header's badge shows for this request."
  [req]
  (service/item-count (current req)))
