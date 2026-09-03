### void/notify/channel — what a notification is handed to.
###
### A channel is a **contribution**, not a component — the shape
### `void/mail` gives transports and `void/html` gives view engines, for
### the same reason: a channel has no state worth starting, and "which
### ones" is a list in the config rather than an ambiguity the kernel
### has to resolve.
###
###     {:name    :mail
###      :doc     "Send the notification as a letter"
###      :address :email                        the key of :to it reads
###      :project (fn [note] payload-or-nil)    data, and queueable
###      :deliver (fn [payload] receipt)        the I/O
###      :permanent? (fn [err] bool)}           is a retry pointless?
###
### **The split between `:project` and `:deliver` is the whole reason
### this contract has two functions instead of one.** Projection runs
### on the fiber that called `notify/send` — where the request's
### identity, locale and CSRF slot still are, and where a letter is
### rendered exactly once — and produces *data*. Delivery takes that
### data and does the network. Which means the payload can be put in a
### queue between them, and the retry delivers **the same value** that
### the request meant: the argument void/mail makes for queueing a
### rendered letter rather than the arguments that would render one,
### generalized to every channel.
###
### `:project` is optional: a channel that needs nothing but the
### notification (the in-app row, `:log`, `:memory`) leaves it out and
### gets the normalized notification as its payload.
###
### **A projection that returns nil skips the channel.** The
### notification carried no address this channel can read, or nothing
### it is interested in — that is not a failure, it is the shape
### `:void.auth/deliver` already has, and `notify/send` reports it as
### `:skipped` rather than pretending something went out.
###
### A **receipt** comes back from `:deliver`: `{:channel :id ...}` plus
### whatever the channel wants to say about the delivery. Two channels
### live here — the two that need nothing at all.

(import void/core/log :as log)
(import ./notification :as notification)

(def log-ns "void.notify")

(defn receipt
  "The value a channel returns: which channel, which notification, and
  whatever else it wants recorded."
  [name payload &opt parts]
  (default parts {})
  (merge {:channel name
          :id (get payload :id)
          :at (get payload :at (os/time))}
         parts))

(defn normalize
  ``Check a `:void.notify/channel` contribution and fill in what it did
  not say. Runs at boot, so a channel that cannot deliver anything is a
  start error rather than a notification that disappears.``
  [c]
  (unless (dictionary? c)
    (errorf "a channel is a table {:name :deliver}, got %q" c))
  (unless (keyword? (get c :name))
    (errorf "a channel needs a keyword :name, got %q" (get c :name)))
  (unless (function? (get c :deliver))
    (errorf "channel %q has no :deliver function" (get c :name)))
  (each key [:project :permanent? :health]
    (when-let [f (get c key)]
      (unless (function? f)
        (errorf "channel %q: %q must be a function, got %q" (get c :name) key f))))
  (unless (or (nil? (get c :address)) (keyword? (get c :address)))
    (errorf "channel %q: :address names a key of :to and must be a keyword, got %q"
            (get c :name) (get c :address)))
  # what `:deliver` needs open where it runs. The split is the reason the
  # key exists: `:project` runs on the request fiber, inside an
  # application whose components are all up, and `:deliver` runs on a
  # worker started by a command that opened exactly what it named. A
  # channel that posts over https needs `:tls/lib` there, and only the
  # channel knows that
  (unless (or (nil? (get c :needs))
              (and (indexed? (get c :needs)) (all keyword? (get c :needs))))
    (errorf "channel %q: :needs is a list of component keys, got %q"
            (get c :name) (get c :needs)))
  (merge {:doc nil :address nil :project nil :permanent? nil :health nil
          :needs []}
         c))

(defn project
  ``The payload a channel is delivered, or nil when the notification
  was not its business. A channel without a `:project` takes the
  notification itself.``
  [channel note]
  (if-let [f (get channel :project)]
    (f note)
    note))

(defn permanent?
  ``Has this channel already had its final answer? A channel that says
  yes turns a failure into a recorded rejection instead of a retry —
  the argument void/mail-jobs makes about a 5xx, asked of every
  channel. A channel that does not answer gets the retry.``
  [channel err]
  (if-let [f (get channel :permanent?)]
    (let [[ok answer] (protect (f err))]
      # a classifier that threw has not said "final", and the retry is
      # the safer of the two mistakes
      (truthy? (and ok answer)))
    false))

# -- :memory — the outbox a test reads -----------------------------------

(var outbox
  ``Payloads the :memory channel kept, newest last. A test asserts on
  this; `void notify outbox` prints it.``
  @[])

(def default-keep
  "How many payloads the memory channel holds on to — bounded for the
  reason void/mail's outbox is: a dev server runs for a week."
  100)

(var keep-count default-keep)

(defn clear!
  "Empty the memory outbox."
  []
  (set outbox @[])
  nil)

(defn memory-channel
  "The channel that delivers into `outbox` — what a test suite runs on."
  []
  {:name :memory
   :doc "Keep notifications in memory; notify/outbox reads them back"
   :deliver (fn memory-deliver [payload]
              (array/push outbox payload)
              (when (> (length outbox) keep-count)
                (set outbox (array/slice outbox (- (length outbox) keep-count))))
              (receipt :memory payload))})

# -- :log — the notification in the log, and nowhere else ----------------

(defn log-channel
  "The channel that logs a notification instead of delivering it."
  []
  {:name :log
   :doc "Log the notification; deliver it nowhere"
   :deliver (fn log-deliver [payload]
              (log/info "notification (not delivered)" :ns log-ns
                        :summary (notification/summary payload))
              (receipt :log payload))})
