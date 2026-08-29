### shop/seed — a catalog to click on, and somebody to sign in as.
###
### Seeding is not a migration: a migration says what the schema is and
### runs once per database, a seed says what a demo starts with and is
### meant to be re-runnable. So this file is **data plus two calls**:
### the idempotence lives in the services (`catalog/ensure-product!`,
### `customers/ensure-account!`) because "a product that exists is left
### alone" is a rule about a catalog, not a property of a fixture.
###
### It sits at `src/` rather than inside a module because it belongs to
### no module — it is the one place in the application that writes to
### two of them.
(import void/core/log :as log)
(import ./modules/catalog/catalog.service :as catalog)
(import ./modules/customers/customers.service :as customers)

(def log-ns "shop.seed")

(def catalog-items
  ``Eight things, priced so that the demo shows every path: one is sold
  out, and one costs an amount ending in 13 cents, which is what the
  payments gateway declines.``
  [{:sku "VOID-MUG" :name "Enamel mug"
    :description "Holds coffee. Survives a fall onto a keyboard, which the keyboard does not."
    :price-cents 1400 :stock 42}
   {:sku "VOID-TEE" :name "Fibers all the way down (t-shirt)"
    :description "Cotton, printed with a stack trace that ends in ev/. Sizes are a lie everywhere, and here too."
    :price-cents 2900 :stock 17}
   {:sku "VOID-CAP" :name "Six-panel cap"
    :description "Embroidered parenthesis. Adjustable, like everything in a lisp."
    :price-cents 2400 :stock 9}
   {:sku "VOID-NOTE" :name "Dotted notebook"
    :description "A5, 192 pages, lies flat. For the design you will throw away twice."
    :price-cents 1213 :stock 30}
   {:sku "VOID-STICK" :name "Sticker sheet"
    :description "Twelve stickers. The laptop lid is the only deployment target that never changes."
    :price-cents 600 :stock 120}
   {:sku "VOID-SOCK" :name "Socks (pair)"
    :description "Merino. Warm enough for a datacentre in winter, which is a place nobody should be."
    :price-cents 1800 :stock 24}
   {:sku "VOID-BAG" :name "Canvas tote"
    :description "Carries a laptop, a notebook and the conference swag you promised not to take."
    :price-cents 2200 :stock 12}
   {:sku "VOID-POSTER" :name "Poster: the plugin lifecycle"
    :description "A0. Every hook, every phase, printed once so nobody has to remember them."
    :price-cents 3500 :stock 0}])

(def staff
  ``The account behind the admin desk. A demo needs one, and printing
  it is the honest way to have one — an unprintable seeded password is
  a password in the source.``
  {:name "Desk" :email "desk@shop.example" :password "desk-desk-desk"})

(def customer
  "Somebody to buy things as, so the demo has an order history the
  first time it is opened."
  {:name "Ada" :email "ada@shop.example" :password "ada-ada-ada-ada"})

(defn seed!
  ``Fill an empty shop. Returns what it did, so the CLI command can say
  it rather than the function printing.``
  []
  (def products (map catalog/ensure-product! catalog-items))
  (def [staff-state _] (customers/ensure-account! (merge staff {:role "staff"})))
  (def [customer-state _] (customers/ensure-account! (merge customer {:role "customer"})))
  (def created (length (filter |(= :created (first $)) products)))
  (log/info "seeded" :ns log-ns
            :products-created created
            :staff staff-state :customer customer-state)
  {:products-created created
   :products-kept (- (length products) created)
   :staff staff-state
   :customer customer-state})
