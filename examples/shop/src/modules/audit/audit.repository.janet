### shop/audit/repository — one insert and one read.
###
### `trail` is filterable by correlation, which is how one request's
### whole causal fan-out (the order, the letter, the capture, the
### retry) is pulled out in one query.
(import void/db :as db)
(import ./audit.model :as model)

(defn record!
  ``Write one line. Raises on a duplicate `message-id`, which is the
  point — see ./audit.consumer.``
  [event]
  (db/insert! model/AuditEvent event))

(defn recorded?
  "Has this message already been written?"
  [message-id]
  (truthy? (db/one model/AuditEvent {:where [:= :message-id message-id]})))

(defn trail
  "The trail, newest first — what the admin desk shows and what a test
  reads."
  [&opt opts]
  (default opts {})
  (db/query model/AuditEvent
            (merge {:order-by [[:id :desc]] :limit (get opts :limit 100)}
                   (if-let [c (get opts :correlation-id)]
                     {:where [:= :correlation-id c]}
                     {}))))
