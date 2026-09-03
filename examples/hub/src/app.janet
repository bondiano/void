### hub/app — the application plugin: what it is made of, and the one
### config slice it owns.
###
### There is no code about a webhook hub in this file. Every route,
### every handler, every entity, every rule and the one channel live in
### `src/modules/<module>/`, and what is left here is the manifest: the
### imports that pull the modules in, two hooks, and the schema of
### `[:hub]`.
###
### **The imports are the wiring.** void has no registry to enrol a
### module in and no loader that scans a directory: `defentity`,
### `defroutes`, `defpolicy`, `defresource-admin` and `contribute!` all
### take effect when their file is *loaded*, so importing a module is
### what composes it, and deleting an import is what takes it out. That
### is why every module is named exactly once, here.
###
### **There is no `admin` module**, for the reason examples/shop has
### none: the desk is a `*.admin.janet` in the module whose rows a person
### looks at. A back office is a *layer* of a module.
###
### The layers inside a module are described in the README; the short
### version is that a **controller** may call a service, a **service**
### may call a repository, a **repository** is the only thing that names
### a table, and a **DTO** is what crosses the boundary in either
### direction.
(import void/core/plugin :as plugin)

# -- the modules ---------------------------------------------------------
#
# Order does not matter (janet's module cache makes every import
# idempotent), so they are listed the way a reader would want them: what
# arrives, where it goes, what carries it out, then the operator's half.

# intake: the receiving end — the route, the signature, the store, the
# row, and the desk that reads them back
(import ./modules/intake/intake.model)
(import ./modules/intake/intake.controller)
(import ./modules/intake/intake.admin)

# routing: where a delivery goes, as data
(import ./modules/routing/routing.service)

# telegram: the notify channel this application wrote — project where the
# request is, deliver where the network is
(import ./modules/telegram/telegram.channel)

# auth: the accounts `void make auth` generated, and the policy that
# decides which of them is an operator
(import ./modules/auth/auth.model)
(import ./modules/auth/auth.controller)
(import ./modules/auth/auth.policy)

# ops: the front door (the jobs dashboard) and the one command
(import ./modules/ops/ops.controller)
(import ./modules/ops/ops.cli)

(import ./modules/intake/intake.service :as intake)
(import ./modules/routing/routing.service :as routing)
(import ./modules/telegram/telegram.channel :as telegram)
(import ./modules/auth/auth.policy :as operators)

# -- hooks ---------------------------------------------------------------
#
# One slice, four readers, one hook. `[:hub]` is this application's whole
# configuration, and each module gets the part it is about — rather than
# four hooks racing to read the same value at the same phase. `void config
# explain :hub :sources` prints which layer put a value there, and no
# layer prints a secret: those are references resolved into boxes.

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 410
   :name :hub/configure
   :doc "Hand each module its part of the [:hub] slice"
   :fn (fn configure [boot]
         (def slice (or (get-in boot [:config :values :hub]) {}))
         (intake/configure! slice)
         (routing/configure! slice)
         (telegram/configure! slice)
         (operators/configure! slice))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 140
   :name :hub/warn-when-nobody
   :doc "Say at start that the desk lets nobody in, rather than at the first 403"
   :fn (fn warn [_boot] (operators/warn-when-nobody!))})

# -- manifest ------------------------------------------------------------

(def Config
  ``Schema of the `[:hub]` slice — this application's whole slice,
  declared here because the hook above is what reads it. Each key names
  the module that is about it.``
  {# ./modules/intake — the sources this hub receives from
   :sources [:optional :dictionary]
   # ./modules/routing — where a received delivery goes
   :rules [:optional [:vector :dictionary]]
   # ./modules/telegram — the bot this application speaks as
   :telegram [:optional :dictionary]
   # ./modules/auth — who may read what was received
   :operators [:optional [:vector :string]]})

(def defaults
  ``No sources, no rules and no operators: an application that has not
  been told about a source answers 404 on every intake path — the right
  thing to do with an endpoint nobody configured — one with no rules
  receives and keeps deliveries without sending anything anywhere, and
  one with no operators opens its desk to nobody.``
  {:sources {} :rules [] :telegram {} :operators []})

(plugin/defplugin hub/app
  :doc "A webhook hub: signed deliveries in, kept verbatim in storage, routed by rules that are data, out to a chat through a queue — and a desk over the queue and the deliveries."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1"
             :void/db ">=0.0.1" :void/db-http ">=0.0.1"
             :void/crypto ">=0.0.1"
             :void/auth ">=0.0.1" :void/auth-http ">=0.0.1" :void/auth-db ">=0.0.1"
             :void/authz ">=0.0.1" :void/authz-http ">=0.0.1"
             :void/security ">=0.0.1"
             :void/mail ">=0.0.1" :void/mail-auth ">=0.0.1"
             :void/storage ">=0.0.1"
             :void/jobs ">=0.0.1"
             :void/notify ">=0.0.1"
             :void/admin ">=0.0.1" :void/admin-jobs ">=0.0.1"}
  :config-key :hub
  :config-schema Config
  :config-defaults defaults)
