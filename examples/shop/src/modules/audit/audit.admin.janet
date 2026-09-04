### shop/audit/admin — the trail on the desk, and the desk on the trail.
###
### Two directions, and neither side knows the other exists.
###
### **The desk's changes go onto the trail.** `void/admin` owns no
### table: it *announces* every change through the core hook
### `:void.admin/changed` and leaves the keeping of it to whoever wants
### it. Here that is the consumer this application has had since wave
### 3.6 — so a product archived at the desk lands in `audit_events`
### under the same correlation id, next to the `order/placed` the
### checkout wrote, and no migration shipped with any of it.
###
### **The trail comes back as a history tab.** `:void.admin/history`
### is the other direction: a single-cardinality point that nobody
### contributes to by default (so there is no history tab by default),
### answered here by reading the table the consumer fills.
###
### And the trail is itself a resource — read-only, because a trail
### editable from the page that displays it is not a trail.
(import void/core/plugin :as plugin)
(import void/db :as db)
(import void/admin :as admin)
(import void/bus :as bus)
(import ../../shared/values :as values)
(import ./audit.model :as model)
(import ./audit.service :as service)

(admin/defresource-admin audit-events model/AuditEvent
  :title "Audit"
  :only [:index :show]
  :list [:id :at :topic :actor :detail]
  :detail [:id :at :topic :actor :correlation-id :detail :message-id]
  :search [:topic :actor :detail]
  :filters [:topic]
  :sortable [:id :at :topic]
  :order-by [[:id :desc]])

# -- the desk's changes, onto the bus ------------------------------------

(defn- record-change!
  ``Turn one `:void.admin/changed` announcement into a bus message,
  which is the entire integration: void/admin does not know what a bus
  is, ./audit.consumer does not know what an admin is, and the trail
  gets the back office for nothing.

  The two ways in need different publishes, and the difference is
  honest rather than defensive. A change made on a page rides
  `publish-tx!` — the admin's writing routes carry `:void.db/txn`, so
  the message and the row it announces commit together or not at all
. A change made by a **bulk job** has no such transaction
  around it (`void/admin-jobs` runs the rows in a worker), and there
  publishing outside one is the truthful thing to do: the row is
  already committed, and an at-least-once message about it is what the
  trail is for.``
  [fact]
  (def topic (keyword "admin/" (fact :action)))
  (def payload {:actor (fact :subject)
                :at (values/now)
                :resource (string (fact :resource))
                :id (fact :id)
                :before (fact :before)
                :after (fact :after)})
  (if (db/in-transaction?)
    (bus/publish-tx! topic payload)
    (bus/publish topic payload)))

(plugin/contribute! :void.core/hooks
  {:hook :void.admin/changed
   :name :shop/admin-audit
   :doc "Announce every admin change on the bus, so the trail this application already keeps records it"
   :fn record-change!})

# -- and the trail, back as a history tab --------------------------------

(plugin/contribute! :void.admin/history
  {:name :shop/history
   :doc "The history tab of a row, over the audit trail this application already writes"
   # the rows about *this* id, selected where they live: the newest
   # fifty of the whole trail would lose a change under a busy queue
   :fn (fn history [{:resource rname :id id}]
         (seq [row :in (service/trail {:limit 50 :match (string ":id " id)})
               :when (string/find (string rname) (or (row :detail) (row :topic)))]
           {:at (row :at) :actor (row :actor) :detail (row :topic)}))})
