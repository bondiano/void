### The audit trail. Written by nothing that knows about it:
### the handlers publish facts on the bus, and blog/audit — a consumer
### like any other — turns them into rows. Deleting that one file stops
### the trail and changes no handler.

(defn up []
  [{:create-table "audit_events"
    :columns [[:id :serial {:primary-key true}]
              # the bus message id, so a row can be traced back to the
              # message that made it — and so a redelivery is
              # recognisable rather than a second row
              [:message-id :text {:null false}]
              [:topic :text {:null false}]
              # every message caused by one request carries the same
              # correlation, which is what makes this table answerable
              # to "what happened when that button was pressed"
              [:correlation-id :text {:null false}]
              [:actor :text]
              [:detail :text {:null false}]
              [:at :text {:null false}]]}

   {:create-index "audit_events_message_idx" :unique true
    :on "audit_events" :columns [:message-id]}

   {:create-index "audit_events_correlation_idx"
    :on "audit_events" :columns [:correlation-id]}])

(defn down []
  {:drop-table "audit_events"})
