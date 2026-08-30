### shop/app — the application plugin: what it is made of, and the two
### things it asks the framework for.
###
### There is no code about a shop in this file. Every route, every
### handler, every entity, every job and every bus consumer lives in
### `src/modules/<module>/`, and what is left here is the manifest:
### the imports that pull the modules in, one CLI command, two hooks
### and a config slice.
###
### **The imports are the wiring.** void has no registry to enrol a
### module in and no loader that scans a directory: `defentity`,
### `defroutes`, `defjob`, `defhandler`, `defpolicy` and `contribute!`
### all take effect when their file is *loaded*, so importing a module
### is what composes it, and deleting an import is what takes it out.
### That is why every module is named exactly once, here, and why
### `src/modules/audit/` can be removed with two lines of change.
###
### The layers inside a module are described in the README; the short
### version is that a **controller** may call a service, a **service**
### may call a repository, a **repository** is the only thing that
### names a table, and a **DTO** is what crosses the boundary in either
### direction.
(import void/core/plugin :as plugin)

# -- the modules ---------------------------------------------------------
#
# Order does not matter (janet's module cache makes every import
# idempotent), so they are listed the way a reader would want them: the
# things a customer touches, then the desk, then the trail.

# catalog: the storefront and its JSON twin
(import ./modules/catalog/catalog.model)
(import ./modules/catalog/catalog.controller)
(import ./modules/catalog/catalog.api)

# cart: the basket that exists before an account does
(import ./modules/cart/cart.model)
(import ./modules/cart/cart.controller)
(import ./modules/cart/cart.jobs)
(import ./modules/cart/cart.telemetry)

# customers: the way in, and the role the desk asks for
(import ./modules/customers/customers.model)
(import ./modules/customers/customers.policy)
(import ./modules/customers/customers.controller)

# orders: the checkout, the payment job, the letters, and what
# subscribes to them
(import ./modules/orders/orders.model)
(import ./modules/orders/orders.policy)
(import ./modules/orders/orders.controller)
(import ./modules/orders/orders.api)
(import ./modules/orders/orders.jobs)
(import ./modules/orders/orders.events)
(import ./modules/orders/orders.telemetry)

# payments: the gateway that is not there
(import ./modules/payments/payments.gateway :as payments)
(import ./modules/payments/payments.telemetry)

# admin: three routes and one role
(import ./modules/admin/admin.controller)

# audit: one consumer, one table, and nothing that calls it
(import ./modules/audit/audit.model)
(import ./modules/audit/audit.consumer)
(import ./modules/audit/audit.service :as audit)

(import ./seed :as seed)

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :shop/seed
   :read-only? false
   :doc "Fill an empty shop with a catalog and two accounts: void shop seed"
   # the components this command needs started, and no others: a pool
   # to write through, the auth registry for the user store and the
   # crypto library, because seeding an account hashes a password
   :needs [:db/pool :auth/registry :crypto/lib]
   :fn (fn cli-seed [_pool _auth _crypto & args]
         (unless (empty? args)
           (errorf "void shop seed takes no arguments (got %q) — the catalog is in src/seed.janet"
                   (string/join args " ")))
         (def out (seed/seed!))
         (printf "%d products created, %d already there"
                 (out :products-created) (out :products-kept))
         (printf "staff:    %s / %s (%s)"
                 (get seed/staff :email) (get seed/staff :password) (out :staff))
         (printf "customer: %s / %s (%s)"
                 (get seed/customer :email) (get seed/customer :password) (out :customer)))})

# -- hooks ---------------------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 500
   :name :shop/configure
   :doc "Read the [:shop] config slice (the payment gateway's failure rate)"
   :fn (fn configure [boot]
         (payments/configure! (get-in boot [:config :values :shop :payments] {})))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   # after the bus started its consumers (:bus/consume is 800): the
   # first denial should have somewhere to go
   :phase 900
   :name :shop/audit
   :doc "Turn void/authz's refusals into bus messages (see modules/audit)"
   :fn audit/install!})

# -- manifest ------------------------------------------------------------

(def Config
  "Schema of the [:shop] config slice."
  {:payments [:optional payments/Config]})

(plugin/defplugin shop/app
  :doc "void shop — a storefront on void/db, void/jobs, void/cache and void/bus, with sign-in, row-level authorization, CSRF, rate limits, a JSON API and an audit trail."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"
             :void/rest ">=0.0.1"
             :void/db ">=0.0.1" :void/db-http ">=0.0.1"
             :void/cache ">=0.0.1" :void/jobs ">=0.0.1"
             :void/obs ">=0.0.1"
             :void/auth ">=0.0.1" :void/auth-http ">=0.0.1" :void/auth-db ">=0.0.1"
             :void/authz ">=0.0.1" :void/authz-http ">=0.0.1"
             :void/security ">=0.0.1"
             :void/mail ">=0.0.1" :void/mail-auth ">=0.0.1"
             :void/bus ">=0.0.1" :void/bus-db ">=0.0.1"}
  :config-key :shop
  :config-schema Config
  :config-defaults {:payments payments/defaults})
