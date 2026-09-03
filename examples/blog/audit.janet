### blog/audit — the trail, and nothing that produces it (exit criterion 1 of wave 3).
###
### This file subscribes to the bus and writes rows. That is all it does,
### and the interesting part is what it does *not* need: no handler in
### ./app calls it, no entity has a callback (says they have none), and no
### middleware is wrapped around anything. Deleting this file stops the
### audit trail and changes nothing else in the application — which is the
### whole claim behind having a bus rather than a function everybody
### remembers to call.
###
### Two kinds of thing end up here, and they arrive by two different
### routes on purpose.
###
### **Domain facts go through the outbox.** `bus/publish-tx!` writes
### the message into the same transaction as the row it announces
### (`:void.db/txn true` on the route is what opened it), so "the
### article was published" and "the article exists" commit together or
### not at all. A rolled-back edit does not leave an audit line saying
### it happened, and a committed one cannot fail to leave one — which
### is exactly the property an audit trail is worthless without, and
### exactly the one that "publish after the commit" does not have.
###
### **Denials go straight out.** A refused request wrote nothing, so
### there is no transaction to ride and nothing to be consistent with:
### `authz/decision-hook` fires, this module publishes, and the worst
### case of losing one is a missing line rather than a lie. Note where
### it comes from — the hook `void/authz` has fired for exactly this
### since it shipped, and the bus is what picks it up.
###
### The consumer is in its own group (`:audit`), so it reads the whole
### log at its own pace and a slow write here never slows the group
### that recounts comments. And `:message-id` is unique in the table,
### so the redelivery an at-least-once bus is entitled to costs a
### rejected insert rather than a duplicated line.

(import void/core/log :as log)
(import void/db :as db)
(import void/authz :as authz)
(import void/bus :as bus)
(import ./entities :as e)

(def log-ns "blog.audit")

(def group
  ``The consumer group this trail reads under. Its own, not the
  application's default: the audit lags when the audit lags, and the
  job that recounts comments does not wait for it.``
  :audit)

# -- what the application publishes --------------------------------------

(defn record-tx!
  ``Announce a domain fact from inside the transaction that made it.
  Called by ./app on the routes that write; `actor` is the signed-in
  author, when there was one.``
  [topic actor detail]
  (bus/publish-tx! topic (merge {:actor actor :at (e/now)} detail)))

# -- what void/authz publishes -------------------------------------------

(defn- field
  ``One field of a payload, whichever way the codec spelled its keys.
  This application runs `:codec :jdn` (config/default.janet), so they
  come back keywords; under the default `:json` they come back
  strings, and a consumer that reads its own publisher's messages
  should not break when a deployment changes its mind about the wire
  format. A consumer that cares declares a schema instead
  (`bus/defevent`), and gets the coerced shape.``
  [payload key]
  (if (nil? (get payload key)) (get payload (string key)) (get payload key)))

(defn- on-decision
  "Publish every refusal. Allows are not published: there are a
  hundred of them on a page with a list, and an audit trail nobody can
  read is not one."
  [decision]
  (unless (decision :allow)
    (def [ok err]
      (protect
        (bus/publish :authz/denied
                     {:policy (string (decision :policy))
                      :subject (or (decision :subject) "anonymous")
                      :reason (decision :reason)
                      :at (e/now)})))
    (unless ok
      # a bus that is unwell must not turn a 403 into a 500
      (log/warn "denial not audited" :ns log-ns
                :err (if (string? err) err (describe err))))))

(defn install!
  "Subscribe to void/authz's decision hook. Called from the plugin's
  :after-start (see ./app)."
  [boot]
  (authz/listen! :blog/audit on-decision))

# -- the consumer --------------------------------------------------------

(bus/defhandler record-audit
  ``Write one line of the trail. Subscribed to `:*`, so it sees the
  application's own facts, void/authz's denials and — because
  `void/bus-jobs` is composed — every lifecycle event of the queue,
  without any of the three knowing this handler exists.``
  {:topic :* :group :audit}
  [msg]
  (def payload (msg :payload))
  (def [ok err]
    (protect
      (db/insert! e/AuditEvent
                  {:message-id (msg :id)
                   :topic (string (msg :topic))
                   :correlation-id (bus/correlation-id msg)
                   :actor (field payload :actor)
                   :detail (string/format "%j" payload)
                   :at (or (field payload :at) (e/now))})))
  (cond
    ok (do (log/debug "audited" :ns log-ns :topic (msg :topic)) :recorded)
    # the unique index on message_id caught a redelivery: the line is
    # already there, and this is the answer rather than an error. A
    # consumer of an at-least-once bus has to be idempotent, and the
    # cheapest honest way to be idempotent is to let the database say so
    (db/one e/AuditEvent {:where [:= :message-id (msg :id)]}) :already-recorded
    (error err)))

(defn trail
  ``The trail, newest first — what a test reads and what an admin page
  would. Filterable by correlation, which is how one request's whole
  causal fan-out is pulled out in one query.``
  [&opt opts]
  (default opts {})
  (db/query e/AuditEvent
            (merge {:order-by [[:id :desc]] :limit (get opts :limit 100)}
                   (if-let [c (get opts :correlation-id)]
                     {:where [:= :correlation-id c]}
                     {}))))
