### deliveries — what arrived, and where its bytes went.
###
### The bytes themselves are not here: they are in void/storage under
### `body-key`, because a delivery is hundreds of kilobytes of somebody
### else's JSON read once a month, and a row is what a person filters by
### (./intake.janet).
###
### `delivery-id` is unique and that is the whole of the idempotency:
### GitHub retries, a retry carries the same `X-GitHub-Delivery`, and
### the second one must not become a second row. The database says so
### rather than the handler, because two workers can be inside the
### handler at once and only one of them can hold this index.
###
### What a step returns is executed: void/db/builder compiles it for
### whichever engine is running, which is what keeps one file portable.

(defn up []
  [{:create-table "deliveries"
    :columns [[:id :serial {:primary-key true}]
              # which configured source it came in on — `[:hub :sources]`
              [:source :text {:null false}]
              # "push", "issues", ... — the sender's own name for it
              [:event :text {:null false}]
              [:delivery-id :text {:null false :unique true}]
              # what the payload was about. Both are the sender's
              # business, so both are nullable: a body this application
              # cannot parse is still a delivery it received
              [:repo :text]
              [:sender :text]
              [:body-key :text {:null false}]
              [:size :integer {:null false}]
              [:received-at :text {:null false}]]}
   # the two questions a list asks: what came in lately, and what came
   # in from this repository
   {:create-index "deliveries_received_idx" :on "deliveries" :columns [:received-at]}
   {:create-index "deliveries_repo_idx" :on "deliveries" :columns [:repo]}])

(defn down []
  [{:drop-table "deliveries"}])
