### intake/model — what a delivery is.
###
### One received webhook. `delivery-id` is the sender's own id for it —
### unique, because a retry is the same delivery and not a second one —
### and `body-key` says where the bytes went rather than holding them:
### hundreds of kilobytes of somebody else's JSON belong in a store and
### not in a row.
(import void/db :as db)

(db/defentity Delivery
  {:id [:int {:db/pk true :db/type "integer"}]
   :source [:string {:db/type "text"}]
   :event [:string {:db/type "text"}]
   :delivery-id [:string {:db/unique true :db/type "text"}]
   # what the payload was about, for the eye and for a filter. Both are
   # optional because both are the sender's business: a delivery whose
   # JSON this application cannot read is still a delivery it received
   :repo [:optional [:string {:db/type "text"}]]
   :sender [:optional [:string {:db/type "text"}]]
   :body-key [:string {:db/type "text"}]
   :size [:int {:db/type "integer"}]
   :received-at [:string {:db/type "text"}]}
  :db/table "deliveries")
