### shop/cart/jobs — the housekeeping this module owes the database.
###
### A module owns its background work the same way it owns its
### queries: nobody is waiting for this, it runs on a schedule, and if
### it does not run tonight nothing is wrong tomorrow.
###
### A shop that never does this has a `carts` table that grows with its
### traffic rather than with its customers — and the stock it holds is
### not held, because a cart reserves nothing (the checkout is what
### takes stock).
###
### It is not an entity callback, because entities in void have none:
### what happens after a write is a job, a bus consumer or nothing.
(import void/jobs :as jobs)
(import ./cart.service :as service)

(def max-age
  ``How long an untouched cart is kept. Long enough that a customer can
  come back after a weekend, short enough that the table is not an
  archive of every browser that ever visited.``
  (* 14 24 60 60))

(jobs/defjob sweep-carts
  "Delete carts nobody has touched in a fortnight. Returns how many
  went."
  {:queue :maintenance}
  []
  (service/sweep-stale! max-age))

(jobs/defschedule nightly-cart-sweep
  "0 4 * * *"
  :sweep-carts)
