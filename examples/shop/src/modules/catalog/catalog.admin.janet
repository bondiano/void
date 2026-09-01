### shop/catalog/admin — the products, as a back office (ADR-0029).
###
### There is not a line of a page in this file. `void/admin` projects
### the declaration below into routes when the route table is built,
### and `void/admin-mcp` projects the same value into tools for an
### agent — so a column added to ./catalog.model is in the list, in the
### form and in the agent's tool on the next request, and nothing here
### had to be told about it.
###
### **A back office is a layer of its module, not a module of its
### own.** Before wave 4 the shop had a `modules/admin/` directory with
### a controller, a view and three hand-written routes; what it did was
### list rows and press a button. That directory is gone, and each
### module now says what its own rows look like on the desk — which is
### the same reason `*.api.janet` lives next to `*.controller.janet`
### rather than in an `api/` module: a second surface onto one module's
### data belongs to that module.
###
### **The two things a declaration cannot get from a schema** are what
### is left here: which columns a person looks at, and what a person
### may *do* to a row that is not create/read/update/delete. Both are
### below; everything else — the types, the bounds, the primary key,
### the enum's members, the foreign keys — is read off `defentity`.
(import void/core/plugin :as plugin)
(import void/admin :as admin)
(import ../../shared/values :as values)
(import ./catalog.model :as model)
(import ./catalog.service :as service)

(admin/defresource-admin products model/Product
  :title "Products"
  # a column with a :value is the one hook a list has, and money is
  # exactly what it is for: `values/format-price` is the only place in
  # this application where cents become "€14.99", and the desk uses
  # that one rather than a second one that would round differently
  # `:image` is in the list, the detail and the form, and this file
  # says nothing else about it: the `:file` type in ./catalog.model
  # resolves to void/storage-admin's upload widget, which draws the
  # thumbnail here, the preview on the detail page and the file input
  # on the form — and stores what is submitted (ADR-0039 §6).
  # `void admin widgets` prints that resolution and why
  :list [:id :sku :image :name
         {:name :price :label "Price"
          :value (fn [row] (values/format-price (row :price-cents)))}
         :stock :status]
  :detail [:id :sku :image :name :description :price-cents :stock :status]
  :search [:sku :name :description]
  :filters [:status]
  :sortable [:id :sku :name :price-cents :stock]
  # the one number a desk edits all day, edited where it is read: the
  # stock cell on the *list* is an htmx form, so correcting a shelf
  # count is not a page load, a form and a redirect. Nothing else is
  # editable in place — a price changed by a mis-click is a price
  # nobody reviewed
  :editable [:stock]
  :form [:sku :name :description :price-cents :stock :status :image]
  :order-by [[:sku :asc]]
  # a product is archived, never deleted: an order's lines point at
  # this row, and a shop that deleted a product would be a shop whose
  # old invoices lost their links (orders.model says the same thing
  # from the other side). `:except` is how a declaration says that —
  # the destroy route does not exist, so there is no button to hide
  # and no policy to remember to write
  :except [:destroy]
  :actions
  {:archive
   {:label "Archive"
    :doc "Take the selected products off the storefront"
    # A declared action is a *domain* call. The rule it stands on —
    # "an archived product does not exist as far as a visitor is
    # concerned" — is in catalog.service, where the storefront's own
    # rules are, and the desk gets it by calling the same function.
    # An action that wrote `status = 'archived'` here would be the
    # second definition of what archiving means.
    :apply (fn archive [row _req] (service/archive! row))
    # and it runs as a job: a catalogue is the table in this
    # application that is allowed to be large, "everything from a
    # discontinued supplier" is a real selection, and N rows is N
    # policy decisions. :void/admin-jobs turns the confirmation into a
    # progress page; without that plugin composed this line is a
    # start-up error naming it, not a surprise at the button
    # (ADR-0029 §7)
    :job true
    :confirm "Archived products disappear from the storefront and stay linked to the orders that bought them."}})

# -- the front page ------------------------------------------------------

(plugin/contribute! :void.admin/dashboard-widget
  {:name :catalog/out-of-stock
   :label "On sale, nothing left"
   :render (fn out-of-stock [_req]
             [:p {:class "admin-stat"} (string (service/out-of-stock-count))])})
