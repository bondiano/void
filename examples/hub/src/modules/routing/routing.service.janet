### routing/service — where a delivery goes, as data.
###
### A rule is a table, not a branch:
###
###     {:when {:event "push" :repo "bondiano/void"}
###      :to   [:telegram]
###      :chat-id "-1001234567890"}
###
### `:when` is a conjunction over the fields of the row the intake wrote
### — `:source :event :repo :sender` — and a field a rule does not
### mention is a field it does not care about. A value is a string
### (exact) or a list of them (any of); nothing else, because the moment
### this grows patterns it stops being a table somebody can read at
### three in the morning and becomes a small language.
###
### **One notification per matching rule**, rather than one per
### delivery: a rule can name the chat it goes to, and two rules with
### two chats cannot be one notification with one address. It also makes
### the failure honest — a rule whose channel is down is that rule's
### failure and not the other rule's.
###
### Matching is a pure function of two values (`matches?`), so the suite
### is a table of examples rather than a running application.
(import void/core/log :as log)
(import void/notify)
(import ./routing.dto :as dto)

(def log-ns "hub.routing")

(var- rules [])

(defn configure!
  "Called from the application's :before-start hook (src/app.janet)."
  [slice]
  (set rules (or (get slice :rules) []))
  (log/info "routing rules ready" :ns log-ns :rules (length rules)))

(defn configured-rules
  "The rules this process is running with."
  []
  rules)

# -- matching ------------------------------------------------------------

(defn value-matches?
  ``One field of `:when` against one field of the delivery. A string is
  exact; a list is "any of these"; anything else is a rule this
  application does not understand, and refusing to match is the safe
  reading of it — a rule nobody can satisfy sends nothing, where a rule
  that matches everything sends everything to the wrong place.``
  [want got]
  (cond
    (string? want) (= want got)
    (indexed? want) (truthy? (some |(= $ got) want))
    false))

(defn matches?
  "Does this rule cover this delivery? A rule with no `:when` covers
  every delivery — which is a thing somebody may well mean."
  [rule delivery]
  (var ok true)
  (eachp [field want] (get rule :when {})
    (unless (value-matches? want (get delivery field)) (set ok false)))
  ok)

(defn matching
  "Every rule that covers this delivery, in the order they were written."
  [delivery]
  (filter |(matches? $ delivery) rules))

# -- dispatch ------------------------------------------------------------

(defn dispatch!
  ``Send one notification per matching rule. Returns what `notify/send`
  said, per rule, so a caller (and a test) can see that a delivery
  nobody routed is a delivery nobody routed — which is a normal outcome,
  not a failure.``
  [delivery &opt payload]
  (def hits (matching delivery))
  (when (empty? hits)
    (log/debug "no rule covers this delivery" :ns log-ns
               :event (delivery :event) :repo (delivery :repo)))
  (seq [rule :in hits]
    (notify/send (dto/note-for rule delivery payload))))
