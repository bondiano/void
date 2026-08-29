### shop/payments/telemetry — how the gateway is behaving.
###
### `retryable` is the interesting series: a shop whose retryable rate
### moves has a payment provider having an afternoon, and that is
### visible here before it is visible in the money.
(import void/obs :as obs)

(def payments-total
  ``Capture attempts by outcome: `captured`, `declined` (the gateway's
  final answer) or `retryable` (it was not an answer at all).``
  (obs/counter :shop/payments-total
    {:doc "Payment capture attempts, by outcome"
     :labels [:outcome]}))

(defn attempt!
  "One capture attempt: :captured, :declined or :retryable."
  [outcome]
  (obs/inc! payments-total [(string outcome)]))
