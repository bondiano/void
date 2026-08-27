### void/db-http — declarative route transactions (SPEC.md §5.9,
### CONTRACTS v1 row `:void.db/txn`).
###
### The one piece of void/db that needs void/http, kept a separate
### plugin so a CLI or worker process never drags the HTTP kernel in:
### a route (or a whole group) marked
###
###     {:void.db/txn true}
###     {:void.db/txn {:isolation :serializable}}
###
### runs its handler inside (db/with-tx ...) — one connection for the
### request, committed when the handler returns a response and rolled
### back when it throws. The wrapper sits at the business phase, so
### parsing, session, auth and validation have all happened before the
### transaction opens and nothing holds a connection while a body is
### being read.
###
### Errors keep their meaning: an `errors/abort` (or any panic) rolls
### the transaction back and then propagates to the error renderers
### untouched — the response is still rendered outside the
### transaction.

(import void/core/plugin :as plugin)
(import void/http/middleware :as middleware)
(import ./state :as state)

(plugin/defcontribution :void.http/route-meta-key
  {:key :void.db/txn
   :schema [:or :boolean {:isolation [:optional :keyword]}]
   :doc "Run the handler inside a database transaction: true, or {:isolation :serializable} passed to the driver's BEGIN"
   :merge :replace})

(defn- tx-opts [rmeta]
  (def v (get rmeta :void.db/txn))
  (if (dictionary? v) v {}))

(plugin/defcontribution :void.http/middleware
  {:name :void.db/txn
   :phase middleware/phase/business
   :doc "Wrap handlers of routes marked :void.db/txn in db/with-tx — a commit on the way out, a rollback on any error"
   :when (fn [rmeta] (truthy? (get rmeta :void.db/txn)))
   :wrap (fn [handler]
           # :when already decided this route wants a transaction; the
           # isolation is read once, at table-build time
           (fn db-txn [req]
             (state/with-tx* (tx-opts (get-in req [:void/route :meta] {}))
                             (fn txn-handler [] (handler req)))))})

(plugin/defplugin void/db-http
  :doc "Declarative route transactions: the :void.db/txn route metadata key runs a handler inside db/with-tx (void/db + void/http)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/db ">=0.0.1" :void/http ">=0.0.1"})
