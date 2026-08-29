### shop/audit/model — one line of the trail.
###
### Written only by ./audit.consumer, and only from a bus message.
### `:message-id` is unique in the table, so the redelivery an
### at-least-once bus is entitled to is recognised by the *database*
### rather than by a consumer trusting itself to be idempotent — which
### is the shape an at-least-once bus asks a writer to have.
(import void/db :as db)

(db/defentity AuditEvent
  {:id [:int {:db/pk true :db/type "integer"}]
   :message-id [:string {:db/unique true :db/type "text"}]
   :topic [:string {:db/type "text"}]
   :correlation-id [:string {:db/type "text"}]
   :actor [:optional [:string {:db/type "text"}]]
   :detail [:string {:db/type "text"}]
   :at [:string {:db/type "text"}]}
  :db/table "audit_events")
