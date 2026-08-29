### shop/payments/gateway — the payment gateway that is not there.
###
### A module with no model and no repository, because it has no table:
### what it owns is a **port to somebody else's system**, and the
### layering that matters for one of those is that exactly one file
### knows the protocol. Every shop has one of these and no demo can
### ship one, so this is a stand-in with the two properties that matter
### for the code *around* it, which is the part worth demonstrating:
###
###   * it can say **no**, finally — a declined card is an answer, and
###     retrying it is a way to annoy a bank
###   * it can fail to say anything at all — a timeout is not an
###     answer, and giving up on it loses money
###
### `capture!` returns the first as a value and raises the second as an
### error, and that difference is the whole contract with
### orders/orders.jobs: a returned decline is recorded and the order is
### cancelled on the spot, a raised timeout is retried with backoff by
### void/jobs and, if it never resolves, arrives on the bus as
### `:jobs/dead`.
###
### **The failure rate is configuration, not a coin.** `[:shop
### :payments :failure-rate]` is 0 in the `:test` profile, which is
### what makes the suite deterministic, and 0.25 in `:dev`, which is
### what makes the retry path visible while you click around.
(import void/core/log :as log)
(import ../../shared/values :as values)

(def log-ns "shop.payments")

(def Config
  "Schema of the [:shop :payments] slice."
  {:failure-rate [:optional [:number {:min 0 :max 1}]]
   :decline-cents [:optional [:int {:min 0 :max 99}]]})

(def defaults
  ``Defaults of the [:shop :payments] slice.

  `:decline-cents` is the deterministic decline: any total ending in
  13 cents comes back refused. A demo needs a way to *make* the
  unhappy path happen without waiting for a quarter of a chance, and
  an amount is the one input a customer can choose.``
  {:failure-rate 0.25
   :decline-cents 13})

(var settings
  "The [:shop :payments] slice, resolved at :before-start."
  defaults)

(defn configure!
  "Read the slice out of the boot value (see src/app.janet's hook)."
  [cfg]
  (set settings (merge defaults (or cfg {})))
  settings)

(defn- reference []
  (string "pay_" (values/token 8)))

(defn capture!
  ``Charge `amount-cents` for an order. Returns

      {:ok true  :reference "pay_…"}
      {:ok false :reason "card declined"}

  and **raises** when the gateway did not answer — the caller is meant
  to tell those two apart, and a function that returned `{:ok false}`
  for both would make that impossible.``
  [amount-cents]
  (when (= (mod amount-cents 100) (get settings :decline-cents 13))
    (log/info "payment declined" :ns log-ns :amount amount-cents)
    (break {:ok false :reason "card declined"}))
  (when (< (math/random) (get settings :failure-rate 0))
    (log/warn "payment gateway did not answer" :ns log-ns :amount amount-cents)
    (error "payment gateway timed out"))
  {:ok true :reference (reference)})
