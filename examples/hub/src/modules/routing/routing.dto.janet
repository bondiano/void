### routing/dto — the notification one rule makes out of one delivery.
###
### This is the value that crosses the boundary: from here it goes to
### `notify/send`, and every channel in the composition projects it
### again into whatever it speaks (ADR-0040). Nothing below touches the
### network or the database — it reads a row and somebody else's JSON
### and returns data, which is why ../../test/route-test.janet is a
### table of examples that boots nothing.

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
  ``A few more words for the channels that have room. Reads the payload
  the sender sent, and says nothing rather than guessing when it is not
  the shape this knows.``
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

(defn note-for
  ``The notification one rule makes out of one delivery. Addresses are
  keyed by what an address *is* (ADR-0040): `:telegram` is a chat, and a
  rule that does not name one leaves the channel to its configured
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
