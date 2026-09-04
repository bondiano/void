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
  ``The trail, newest first — what the admin desk shows and what a test
  reads. Options: :limit (100), :correlation-id (one request's lines),
  :match (a substring the detail must carry — the row a history tab is
  about, filtered where the rows are rather than in the newest
  hundred of everything).``
  [&opt opts]
  (default opts {})
  (def clauses @[])
  (when-let [c (get opts :correlation-id)]
    (array/push clauses [:= :correlation-id c]))
  (when-let [m (get opts :match)]
    (array/push clauses [:like :detail (string "%" m "%")]))
  (db/query model/AuditEvent
            (merge {:order-by [[:id :desc]] :limit (get opts :limit 100)}
                   (case (length clauses)
                     0 {}
                     1 {:where (first clauses)}
                     {:where [:and ;clauses]}))))
