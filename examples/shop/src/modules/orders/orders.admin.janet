### shop/orders/admin — the desk (ADR-0029).
###
### The three things this file says are the three a projection of
### `defentity` cannot know, and each of them is one line.
###
### **What may not happen.** `:only [:index :show]` — an order is
### placed by a customer at a checkout, and the desk does not type one
### in. That is not a hidden button: the create, edit, update and
### destroy *routes do not exist*, which `void routes` shows and
### `test/admin-test.janet` asserts by looking for them.
###
### **What may.** `:ship` is a declared action, and what it does is
### call `orders.service/ship!` — the same function the shop has had
### since wave 2, holding the same rule ("only a paid order can ship")
### next to the same write. The desk gained a button, not a second
### opinion about the state machine.
###
### **What is somebody else's page.** An order's *lines* are not
### redrawn here. The storefront already renders them at
### `/orders/:number`, `:orders/own` already lets staff read any
### order's page, and a back office that redraws a page the
### application already has is a second place for it to be wrong. The
### list carries a link, and the lines themselves are declared below
### with `:mount false` — a declaration for the agent, not a section.
(import void/core/plugin :as plugin)
(import void/admin :as admin)
(import ../../shared/values :as values)
(import ./orders.model :as model)
(import ./orders.service :as service)

(admin/defresource-admin orders model/Order
  :title "Orders"
  :only [:index :show]
  :list [:number :email :status
         {:name :total :label "Total"
          :value (fn [row] (values/format-price (row :total-cents)))}
         :placed-at
         {:name :lines :label ""
          :value (fn [row] [:a {:href (string "/orders/" (row :number))} "lines →"])}]
  :detail [:id :number :customer-id :email :status :total-cents
           :placed-at :paid-at :shipped-at]
  :search [:number :email]
  :filters [:status]
  :sortable [:id :number :status :placed-at :total-cents]
  :order-by [[:id :desc]]
  :actions
  {:ship
   {:label "Mark shipped"
    :doc "Hand the selected paid orders to the courier"
    # The whole of the desk's write, and every consequence of it is
    # somebody else's: `ship!` publishes `:order/shipped` inside the
    # transaction the bulk route declares (`:void.db/txn`), a bus
    # consumer mails the dispatch notice, and the audit module writes
    # the line. Neither this file nor the operator pressing the button
    # knows about any of that.
    #
    # An order that is not paid is left alone rather than refused:
    # `ship!` answers nil, because "only a paid order can ship" is a
    # state transition and lives with the write (orders.service).
    :apply (fn ship [row _req] (service/ship! row))
    :confirm "The selected orders will be marked shipped and their customers told."}})

# -- the two tables an order is made of, for whoever reads rather than
# -- clicks --------------------------------------------------------------
#
# `:mount false` is a declaration without a section (ADR-0029 §1): no
# routes, no menu entry, and still a resource — so
# `admin-order-items-list` and `admin-payments-list` are tools an agent
# can call, under the same gate and the same per-action policies as
# everything else, while the desk keeps one page per thing a person
# does.

(admin/defresource-admin order-items model/OrderItem
  :title "Order lines"
  :mount false
  # a line is a copy of what was sold, not a link to what is on sale
  # now (orders.model) — so there is nothing here anybody may edit
  :only [:index :show]
  :list [:id :order-id :sku :name :quantity :unit-price-cents]
  :filters [:order-id]
  :order-by [[:id :asc]])

(admin/defresource-admin payments model/Payment
  :title "Payments"
  :mount false
  :only [:index :show]
  :list [:id :order-id :status :amount-cents :reference :attempts :updated-at]
  :filters [:order-id :status]
  :order-by [[:id :desc]])

# -- the front page ------------------------------------------------------

(plugin/contribute! :void.admin/dashboard-widget
  {:name :orders/awaiting-shipment
   :label "Paid, not yet shipped"
   :render (fn awaiting [_req]
             [:p {:class "admin-stat"} (string (service/awaiting-shipment))])})

(plugin/contribute! :void.admin/dashboard-widget
  {:name :orders/placed
   :label "Placed, not yet settled"
   :render (fn placed [_req]
             [:p {:class "admin-stat"} (string (service/unsettled))])})

# -- and a way back ------------------------------------------------------

(plugin/contribute! :void.admin/menu
  {:name :shop/storefront :label "← the shop" :href "/"})
