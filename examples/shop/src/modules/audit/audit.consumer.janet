### shop/audit/consumer — the trail, and nothing that produces it.
###
### This file subscribes to the bus and writes rows. That is all it does,
### and the interesting part is what it does *not* need: no controller
### calls it, no entity has a callback (says they have none), and no
### middleware is wrapped around anything. Delete the audit module and the
### trail stops and nothing else in the shop changes — which is the whole
### claim behind having a bus rather than a function everybody remembers
### to call.
###
### It subscribes to `:*`, so one table ends up holding three kinds of
### thing that arrive by three different routes:
###
### **Domain facts ride the outbox.** `bus/publish-tx!` writes the
### message into the same transaction as the row it announces
### (orders/orders.service), so "this order was placed" and "this order
### exists" commit together or not at all. A checkout that rolled back
### because the last unit went to somebody else leaves no line saying
### it happened, and one that committed cannot fail to leave one.
###
### **The queue's lifecycle arrives for free.** void/bus-jobs forwards
### `:enqueued`/`:started`/`:completed`/`:failed`/`:dead` onto the bus,
### so "the card was charged at 14:02, after two attempts" is in the
### same table as "the order was placed at 14:01" — and the shop wrote
### none of it.
###
### **Denials arrive from ./audit.service**, which listens to
### void/authz's decision hook.
###
### The consumer reads under its own group (`:audit`), so a slow write
### here never holds up the handlers that mail receipts.
(import void/core/log :as log)
(import void/bus :as bus)
(import ../../shared/values :as values)
(import ./audit.repository :as repo)

(def log-ns "shop.audit")

(def group
  ``The consumer group this trail reads under. Its own, not the
  application's default: the audit lags when the audit lags, and the
  letter that follows an order does not wait for it.``
  :audit)

(defn- field
  "One field of a payload, whichever way the codec spelled its keys."
  [payload key]
  (if (nil? (get payload key)) (get payload (string key)) (get payload key)))

(bus/defhandler record-audit
  ``Write one line of the trail. Subscribed to `:*`, so it sees the
  shop's own facts, void/authz's denials and every lifecycle event of
  the queue, without any of the three knowing this handler exists.``
  {:topic :* :group :audit}
  [msg]
  (def payload (msg :payload))
  (def [ok err]
    (protect
      (repo/record! {:message-id (msg :id)
                     :topic (string (msg :topic))
                     :correlation-id (bus/correlation-id msg)
                     :actor (field payload :actor)
                     :detail (string/format "%j" payload)
                     :at (or (field payload :at) (values/now))})))
  (cond
    ok (do (log/debug "audited" :ns log-ns :topic (msg :topic)) :recorded)
    # the unique index on message_id caught a redelivery: the line is
    # already there, and this is the answer rather than an error. A
    # consumer of an at-least-once bus has to be idempotent, and the
    # cheapest honest way to be idempotent is to let the database say so
    (repo/recorded? (msg :id)) :already-recorded
    (error err)))
