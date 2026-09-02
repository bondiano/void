### hub/route — where a delivery goes, as data.
###
### A rule is a table, not a branch:
###
###     {:when {:event "push" :repo "bondiano/void"}
###      :to   [:telegram]
###      :chat-id "-1001234567890"}
###
### `:when` is a conjunction over the fields of the row the intake
### wrote — `:source :event :repo :sender` — and a field a rule does
### not mention is a field it does not care about. A value is a string
### (exact) or a list of them (any of); nothing else, because the
### moment this grows patterns it stops being a table somebody can read
### at three in the morning and becomes a small language.
###
### **One notification per matching rule**, rather than one per
### delivery: a rule can name the chat it goes to, and two rules with
### two chats cannot be one notification with one address. It also
### makes the failure honest — a rule whose channel is down is that
### rule's failure and not the other rule's.
###
### Matching is a pure function of two values (`matches?`), so the
### suite is a table of examples rather than a running application.
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/notify)

(def log-ns "hub.route")

(var- rules [])

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 410
   :name :hub/rules
   :doc "Resolve [:hub :rules] — where a received delivery is sent"
   :fn (fn configure [boot]
         (set rules (or (get-in boot [:config :values :hub :rules]) []))
         (log/info "routing rules ready" :ns log-ns :rules (length rules)))})

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

# -- what the message says -----------------------------------------------

(defn- commit-line [payload]
  (def head (get payload :head_commit))
  (when (dictionary? head)
    (def message (string (get head :message "")))
    (def first-line (first (string/split "\n" message)))
    (unless (empty? first-line) first-line)))

(defn title-of
  "The one line every channel shows: what happened, and where."
  [delivery]
  (string (or (delivery :repo) (delivery :source))
          " — " (delivery :event)
          (if-let [who (delivery :sender)] (string " by " who) "")))

(defn body-of
  ``A few more words for the channels that have room. Reads the
  payload the sender sent, and says nothing rather than guessing when
  it is not the shape this knows.``
  [delivery payload]
  (def parts @[])
  (when (dictionary? payload)
    (case (delivery :event)
      "push"
      (do
        (when-let [ref (get payload :ref)] (array/push parts ref))
        (def commits (get payload :commits))
        (when (indexed? commits)
          (array/push parts (string (length commits)
                                    (if (= 1 (length commits)) " commit" " commits"))))
        (when-let [line (commit-line payload)] (array/push parts line)))

      # every other event: the action and whatever the object calls
      # itself — the two fields GitHub is consistent about
      (do
        (when-let [action (get payload :action)] (array/push parts action))
        (each key [:issue :pull_request :release :discussion]
          (when-let [object (get payload key)]
            (when (dictionary? object)
              (when-let [t (or (get object :title) (get object :name))]
                (array/push parts (string t)))))))))
  (if (empty? parts) nil (string/join parts " · ")))

# -- dispatch ------------------------------------------------------------

(defn note-for
  ``The notification one rule makes out of one delivery. Addresses are
  keyed by what an address *is* (ADR-0040): `:telegram` is a chat, and
  a rule that does not name one leaves the channel to its configured
  default.``
  [rule delivery payload]
  (def to (if-let [chat (get rule :chat-id)] {:telegram chat} {}))
  {:key :hub/delivery
   :title (title-of delivery)
   :body (body-of delivery payload)
   :to to
   :channels (get rule :to [])
   :data {:delivery (delivery :delivery-id)
          :source (delivery :source)
          :event (delivery :event)
          :repo (delivery :repo)
          :sender (delivery :sender)
          :key (delivery :body-key)}})

(defn dispatch!
  ``Send one notification per matching rule. Returns what `notify/send`
  said, per rule, so a caller (and a test) can see that a delivery
  nobody routed is a delivery nobody routed — which is a normal
  outcome, not a failure.``
  [delivery &opt payload]
  (def hits (matching delivery))
  (when (empty? hits)
    (log/debug "no rule covers this delivery" :ns log-ns
               :event (delivery :event) :repo (delivery :repo)))
  (seq [rule :in hits]
    (notify/send (note-for rule delivery payload))))

(plugin/defplugin hub/route
  :doc "Where a received delivery goes: rules are data, matching is a pure function, and each matching rule is its own notification."
  :version "0.1.0"
  :requires {:void/notify ">=0.0.1"})
