### shop/orders/events — what happens *because* something happened.
###
### ./orders.service writes an order and announces it. It does not send a
### letter, and it does not know that one is sent: `bus/publish-tx!` puts
### `:order/placed` in the outbox, and the handlers below subscribe.
### Delete this file and the shop still takes orders and charges cards —
### it just goes quiet, which is exactly the amount of coupling a
### notification deserves.
###
### **The letters go out through the queue without a word here.**
### `mail/send` renders the message on this fiber and hands it to
### void/jobs, because void/mail-jobs is in the composition
### (main.janet). This file does not know that, cannot tell, and would
### keep working if the queue were taken away — the transport would
### simply be whatever `[:mail :transport]` names, on this fiber.
###
### **A consumer of an at-least-once bus can be handed a message
### twice**. For an audit row the answer is a unique index
### (the audit module); for a letter it is a judgement call, and this
### shop's is that a duplicated receipt is a nuisance while a missing
### one is a support ticket. The alternative — recording every sent
### letter and checking first — is a table, and it is the right one for
### a shop that sends invoices. It is written here as a comment rather
### than as code because pretending the question does not exist would
### be the dishonest option.
(import void/core/log :as log)
(import void/bus :as bus)
(import void/mail :as mail)
(import ./orders.repository :as repo)
(import ./orders.mailer :as mailer)

(def log-ns "shop.orders.events")

(defn- field
  ``One field of a payload, whichever way the codec spelled its keys.
  This application runs `:codec :jdn` (config/default.janet), so they
  come back keywords; under the default `:json` they come back
  strings, and a consumer that reads its own publisher's messages
  should not break when a deployment changes its mind about the wire
  format.``
  [payload key]
  (if (nil? (get payload key)) (get payload (string key)) (get payload key)))

(defn- order-of [msg]
  (when-let [id (field (msg :payload) :order)]
    (repo/find-by-id id)))

(bus/defhandler send-receipt
  ``The letter that follows an order. Subscribed to the fact, not
  called by the checkout — which is why a shop that stops mailing
  receipts is a deleted handler and not an edit to the transaction
  that takes the money.``
  {:topic :order/placed}
  [msg]
  (if-let [order (order-of msg)]
    (do
      (mail/send (merge (mailer/receipt order (repo/items-of (order :id)))
                        {:to (order :email)}))
      (log/info "receipt queued" :ns log-ns :order (order :number))
      :sent)
    :gone))

(bus/defhandler send-cancellation
  "The apology, when a payment could not be taken (./orders.jobs)."
  {:topic :order/cancelled}
  [msg]
  (if-let [order (order-of msg)]
    (do
      (mail/send (merge (mailer/cancelled order (or (field (msg :payload) :reason)
                                                    "the payment could not be taken"))
                        {:to (order :email)}))
      :sent)
    :gone))

(bus/defhandler send-dispatch-notice
  "The one people actually open — published by the admin desk."
  {:topic :order/shipped}
  [msg]
  (if-let [order (order-of msg)]
    (do
      (mail/send (merge (mailer/shipped order) {:to (order :email)}))
      :sent)
    :gone))

(bus/defhandler note-dead-job
  ``Every job that exhausted its attempts, on one line. void/bus-jobs
  puts the queue's lifecycle on the bus, so this shop hears about a
  dead job without void/jobs knowing anybody is listening — and
  `capture-payment` cancels its own order on the last attempt
  (./orders.jobs), so anything arriving here is something nobody has
  handled.``
  {:topic :jobs/dead}
  [msg]
  (def payload (msg :payload))
  (log/warn "job died" :ns log-ns
            :job (field payload :job)
            :queue (field payload :queue)
            :err (field payload :error))
  :noted)
