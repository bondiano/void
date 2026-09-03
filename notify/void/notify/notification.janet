### void/notify/notification — a notification is a table.
###
###     {:key   :order/shipped          what happened — required
###      :title "Your order shipped"    the one line every channel has — required
###      :to    {:subject "user:42" :email "ada@example.com"}
###      :body  "Order #1042 is on its way."
###      :url   "/orders/1042"
###      :data  {:order 1042}
###      :mail  {:view [:p ...]}}       a channel's own override
###
### There is no notification *class* with a `via()` and five `toX`
### methods. A notification is data all the way to the channel, for the
### three reasons void/mail gives for a message being data: it can be an argument
### of a job, compared field by field in a test, and printed whole in a
### log.
###
### **Two fields are required and the rest are not.** `:key` names what
### happened — it is what a listing filters on and what a preference
### would one day switch off, and a notification without one cannot be
### talked about after it is sent. `:title` is the one line every
### channel has somewhere to put: a mail subject, a row in the bell, a
### field in a webhook body. Everything else is a channel's business,
### and a channel that needs more than the notification carries takes
### it from an override.
###
### **An override is a key named after a channel.** `{:mail {:subject
### "..."}}` is merged over what the mail channel projected, so an
### application that wants a real letter for one notification writes
### the letter there and leaves every other channel alone. The rule is
### one rule — *a key that names a contributed channel is that
### channel's override* — rather than a per-channel API, because a
### channel contributed by an application gets it for free.
###
### **`:to` is a table of addresses, keyed by what an address is** —
### `:subject` for the in-app row, `:email` for the letter, `:url` for
### the webhook — and not by channel: two channels that mail somewhere
### read the same `:email`, and a recipient stops being a copy of the
### channel list. A bare string is the shorthand for the single-channel
### case and an **error** when the notification goes to several, because
### "which of these is that address for" has no answer worth guessing.

(defn- token [n]
  (string/join (map |(string/format "%02x" $) (os/cryptorand n)) ""))

(defn make-id
  ``A notification's id — minted once, in `notify/send`, and carried by
  every channel: the row in the bell, the `X-Void-Notification` header
  of the letter and the `id` field of the webhook body are the same
  string, which is what lets a consumer of two of them tell that it is
  looking at one event.``
  []
  (string "ntf_" (token 12)))

(defn normalize
  ``A notification plus the channels it is going to, resolved into the
  value every channel below reads. `channels` is the ordered list of
  channel names; `opts` may carry `:id` and `:at`, so a test compares
  values rather than clocks.

  Throws with the missing piece named: an unaddressed or unnamed
  notification is a bug in the calling code, not a delivery failure to
  retry.``
  [note channels &opt opts]
  (default opts {})
  (unless (dictionary? note)
    (errorf "a notification is a table, got %q" note))
  (def key (get note :key))
  (unless (keyword? key)
    (errorf (string "a notification needs a keyword :key naming what happened "
                    "(:order/shipped), got %q") key))
  (def title (get note :title))
  (unless (and (bytes? title) (not (empty? (string title))))
    (errorf "notification %q has no :title — the one line every channel shows" key))
  (def to (get note :to))
  (cond
    (dictionary? to)
    (eachp [k v] to
      (unless (keyword? k)
        (errorf (string ":to is keyed by what an address is (:email :subject :url), "
                        "and %q is not a keyword") k)))

    (bytes? to)
    (when (> (length channels) 1)
      (errorf (string "notification %q carries the bare address %q and goes to %s — "
                      "a string says nothing about which of them it is for. Pass a "
                      "table: {:email \"...\" :subject \"user:42\"}")
              key (string to)
              (string/join (map |(string/format "%q" $) channels) " ")))

    (nil? to)
    (errorf (string "notification %q has no :to — a notification is addressed even "
                    "when the channel knows where it goes") key)

    (errorf ":to is a table of addresses or a single address string, got %q" to))
  (def data (get note :data))
  (unless (or (nil? data) (dictionary? data))
    (errorf "notification %q: :data is a table, got %q" key data))
  @{:id (get opts :id (make-id))
    :at (get opts :at (os/time))
    :key key
    :title (string title)
    :body (when-let [b (get note :body)] (string b))
    :url (when-let [u (get note :url)] (string u))
    :data (or data {})
    :to to
    :channels (tuple ;channels)
    # only the overrides of the channels this notification is actually
    # going to: what is not delivered is not carried into a queue
    :overrides (tabseq [c :in channels :when (dictionary? (get note c))]
                 c (get note c))})

(defn normalized?
  "Has this notification been through `normalize`? What a channel
  asserts before it projects anything."
  [note]
  (and (dictionary? note)
       (keyword? (get note :key))
       (string? (get note :id))
       (indexed? (get note :channels))))

(defn address-for
  ``The address `channel` reads off this notification, or nil when
  there is none. `channel` is a normalized contribution: its
  `:address` names the key of `:to` it takes (`:email`, `:subject`,
  `:url`), and a channel that declares none is one that knows where it
  is going from configuration.

  nil is not a failure here — it is how a channel says the
  notification was not its business, the shape `:void.auth/deliver`
  already has.``
  [note channel]
  (def want (get channel :address))
  (def to (get note :to))
  (cond
    (nil? want) nil
    (bytes? to) (string to)
    (when-let [v (get to want)] (string v))))

(defn override-for
  "What this notification says about `channel-name`, or an empty table."
  [note channel-name]
  (get-in note [:overrides channel-name] {}))

(defn summary
  "One line about a notification, for a log record or a CLI listing."
  [note]
  (string/format "%s %q -> %s: %s"
                 (get note :id "?")
                 (get note :key :?)
                 (let [to (get note :to)]
                   (if (dictionary? to)
                     (string/join (sorted (map string (keys to))) ",")
                     (string to)))
                 (get note :title "")))
