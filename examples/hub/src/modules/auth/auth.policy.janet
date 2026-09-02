### auth/policy — who is an operator.
###
### **A list, not a table.** `[:hub :operators]` names the addresses
### that may come in. A hub has one or two of them, a column on `users`
### would need a migration and a page to edit it, and a list in config is
### a thing a deployment already knows how to set
### (`VOID_HUB__OPERATORS='["ada@example.com"]'`). The list is empty by
### default, which means the desk is shut by default — registration on
### this application is open, and an open registration plus "anybody
### signed in is staff" is a hub anybody can read.
(import void/core/log :as log)
(import void/authz :as authz)

(def log-ns "hub.auth.policy")

(var- operators
  "The addresses `[:hub :operators]` names, read once at start."
  [])

(defn configure!
  "Called from the application's :before-start hook (src/app.janet)."
  [slice]
  (set operators (or (get slice :operators) []))
  # the count, not the addresses: a log line is the one place a list of
  # who has access should not be
  (log/info "operators ready" :ns log-ns :operators (length operators)))

(defn warn-when-nobody!
  "Say at start that the desk lets nobody in, rather than at the first
  403."
  []
  (when (empty? operators)
    (log/warn (string "the desk refuses everybody: [:hub :operators] names "
                      "no address. Set it to the addresses that may read "
                      "deliveries — VOID_HUB__OPERATORS='[\"you@example.com\"]'")
              :ns log-ns)))

(authz/defpolicy :hub/operator
  ``The gate `[:admin :access]` names. The identity carries the address
  as a claim (`[:auth-db :users :claims-columns]`), so this decision
  costs no query — which is what `attr` is for (ADR-0024 §2).

  Both refusals are sentences rather than `false`, because a policy that
  says why is a policy an operator can act on: `void authz explain`
  prints exactly this string.``
  [ctx]
  (def email (authz/attr ctx :subject/email))
  (cond
    (nil? email) "not signed in"
    (index-of email operators) true
    "not an operator of this hub — [:hub :operators] does not name this address"))
