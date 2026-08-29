### shop/cart/telemetry — the one number this module is judged on.
###
### void/obs already answers "how many requests, how fast, how many
### 500s" from the route table (ADR-0021): nothing in a `*.telemetry`
### file is about HTTP. What is here is the half only the application
### knows, and it is declared at module load so the hot path does no
### work but the write.
###
### This one is **pull-based**. "How many carts are open" is a property
### of the database, not a count of events this process saw, so it is a
### gauge with a `:collect` thunk: one indexed query, at scrape time, on
### the process being scraped. A gauge that handlers incremented would
### drift the first time the sweep deleted one.
(import void/obs :as obs)
(import void/db :as db)

(def open-carts
  "Carts with something in them, right now."
  (obs/gauge :shop/open-carts
    {:doc "Carts that currently hold at least one line"
     :collect (fn collect-open-carts []
                (db/value {:select [[:raw "count(distinct cart_id) AS n"]]
                           :from "cart_items"}))}))
