### shop/audit/service — the trail, and the one thing that feeds it
### which is not already a bus message.
###
### void/authz fires a hook for every decision. A refused request wrote
### nothing, so there is no transaction to ride and nothing to be
### consistent with: this module publishes the refusal onto the bus,
### and ./audit.consumer writes it like anything else. The worst case
### of losing one is a missing line rather than a lie.
###
### **Allows are not published.** There are a hundred of them on a page
### with a catalog on it, and an audit trail nobody can read is not one.
(import void/core/log :as log)
(import void/authz :as authz)
(import void/bus :as bus)
(import ../../shared/values :as values)
(import ./audit.repository :as repo)

(def log-ns "shop.audit")

(defn- on-decision [decision]
  (unless (decision :allow)
    (def [ok err]
      (protect
        (bus/publish :authz/denied
                     {:policy (string (decision :policy))
                      :subject (or (decision :subject) "anonymous")
                      :reason (decision :reason)
                      :at (values/now)})))
    (unless ok
      # a bus that is unwell must not turn a 403 into a 500
      (log/warn "denial not audited" :ns log-ns
                :err (if (string? err) err (describe err))))))

(defn install!
  "Subscribe to void/authz's decision hook. Called from the plugin's
  :after-start (src/app.janet)."
  [boot]
  (authz/listen! :shop/audit on-decision))

(defn trail
  "The trail, newest first."
  [&opt opts]
  (repo/trail opts))
