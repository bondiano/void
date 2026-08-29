### shop/orders/jobs — the work that must not happen on the request
### path.
###
### `capture-payment` is money. It is enqueued **by the checkout
### transaction** (void/jobs-db keeps the queue in the same database,
### so the record and the order commit together), it retries a gateway
### that did not answer with backoff and jitter, and it treats a
### decline as an answer rather than as something to retry. On its last
### attempt it stops trying and cancels the order, putting the stock
### back — a compensation, because the checkout already took it.
###
### The job is the only thing in this application that talks to the
### payments module, and all it knows about it is the difference
### between a returned `{:ok false}` and a raise.
(import void/core/log :as log)
(import void/jobs :as jobs)
(import ../payments/payments.gateway :as gateway)
(import ../payments/payments.telemetry :as payments-telemetry)
(import ./orders.repository :as repo)
(import ./orders.service :as service)

(def log-ns "shop.orders.jobs")

(jobs/defjob capture-payment
  ``Charge for one order.

  `:unique :args` because a retry of the *enqueue* (a redelivered
  message, an operator running it again) must not charge twice; the
  first thing the body does is check the order's state, because
  uniqueness in the queue is not uniqueness over time.

  `:max-attempts 5` with void/jobs' exponential backoff and jitter is
  for the gateway that did not answer. A gateway that answered "no" is
  not retried at all — see the payments module for why those are
  different returns.``
  {:queue :payments :max-attempts 5 :unique :args}
  [order-id]
  (def order (repo/find-by-id order-id))
  (def payment (when order (repo/latest-payment order-id)))
  (cond
    (nil? order) :gone
    (nil? payment) :gone
    (not= "placed" (order :status)) :already-settled

    (do
      (def [answered result]
        (protect (gateway/capture! (payment :amount-cents))))

      (cond
        # the gateway did not answer. void/jobs retries this — unless
        # this was the last attempt, in which case the order is
        # cancelled here rather than in a dead-letter queue nobody
        # reads, and the stock goes back
        (not answered)
        (do
          (payments-telemetry/attempt! :retryable)
          (if (jobs/last-attempt?)
            (do
              (service/settle-cancelled! order payment
                                         "the payment gateway never answered"
                                         (jobs/attempt))
              (log/warn "payment abandoned" :ns log-ns
                        :order (order :number) :attempts (jobs/attempt))
              :abandoned)
            (error result)))

        # it answered, and the answer was no
        (not (result :ok))
        (do
          (payments-telemetry/attempt! :declined)
          (service/settle-cancelled! order payment (result :reason) (jobs/attempt))
          (log/info "payment declined" :ns log-ns
                    :order (order :number) :reason (result :reason))
          :declined)

        (do
          (payments-telemetry/attempt! :captured)
          (service/settle-paid! order payment (result :reference) (jobs/attempt))
          (log/info "payment captured" :ns log-ns
                    :order (order :number) :reference (result :reference))
          :captured)))))
