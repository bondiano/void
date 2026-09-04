### void/notify — one notification, several channels.
###
### The shape of this package is one sentence: **a notification is
### data, a channel is a contribution, and which channels a
### notification goes out on is decided by what the application
### composed — not by which function it called.**
###
###     (import void/notify :as notify)
###
###     (notify/send {:key :order/shipped
###                   :title "Your order shipped"
###                   :body "Order #1042 is on its way."
###                   :url "/orders/1042"
###                   :to {:subject (string "user:" (user :id))
###                        :email (user :email)}})
###
### With `:void/notify-mail` composed that is a letter, with
### `:void/notify-inapp` a row in the bell, with `:void/notify-webhook`
### a signed POST — and with all three it is all three, from the one
### call. Add `:void/notify-jobs` and every one of them goes out on a
### worker, with the call site unchanged, for the reason
### `void/mail-jobs` gives: whether this deployment has a worker is a
### fact about the deployment.
###
### Five plugins' worth of composition:
###
###     :void/notify          the kernel (this file)
###     :void/notify-mail     the notification as a letter (./mail)
###     :void/notify-inapp    a row and an htmx bell (./inapp)
###     :void/notify-webhook  a signed POST (./webhook)
###     :void/notify-jobs     delivery through void/jobs (./jobs)
###
### `[:notify :channels]` names the channels this process delivers on;
### left unsaid it is **every contributed channel that actually
### delivers something**, which is the composition read back — the two
### the kernel ships (`:memory`, `:log`) are never in it, and in the
### `:prod` profile a composition whose channels all keep notifications
### rather than delivering them is a boot error. That is the same
### refusal `[:mail :transport]` makes, for the same reason: a
### deployment that silently notifies nobody looks exactly like one
### that works.
###
### What is deliberately not here: preferences ("this user wants no
### mail about shipping"), digests, and a `:sms` channel. The first is
### an application's table and a `:channels` list computed from it — a
### one-line argument to `notify/send`; the last two are named in
### as the things a real application should ask for before
### void guesses at them.

(import void/core/plugin :as plugin)
(import void/core/hooks :as hooks)
(import void/core/log :as log)
(import ./channel :as channel)
(import ./notification :as notification)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.notify")

# -- extension point -----------------------------------------------------

(plugin/defextension-point :void.notify/channel
  :doc "Notification channels: {:name :mail :deliver (fn [payload] receipt) :project (fn [note] payload-or-nil)? :address :email? :permanent? (fn [err] bool)? :needs [component-keys]? :doc string?}; [:notify :channels] names the ones this process delivers on. :project runs where notify/send was called and returns data; :deliver runs where the delivery happens — on a worker, with void/notify-jobs composed. :needs is what :deliver needs *started* there: a worker is a CLI command, a command starts what it declared and nothing else, and a channel that posts over https is the only thing that knows it needs :tls/lib — void/notify-jobs hands the union of the active channels' :needs to the delivery job (void/jobs/job)"
  :schema {:name :keyword
           :doc [:optional :string]
           :address [:optional :keyword]
           :project [:optional :function]
           :deliver :function
           :permanent? [:optional :function]
           :needs [:optional [:vector :keyword]]
           :health [:optional :function]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate notification channel %q" (c :name)))
                (put seen (c :name) true)))
  :reduce (fn [contribs] (tabseq [c :in contribs] (c :name) (channel/normalize c))))

(plugin/contribute! :void.core/interface
  {:name :void/notify
   :doc "The resolved notifier: the channels this composition has, the ones it delivers on and the [:notify] slice behind them."
   :methods {:channels "every contributed channel, by name"
             :active "the channel names this process delivers on"
             :settings "the [:notify] slice as it was resolved"}})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:notify] config slice."
  {:channels [:optional [:vector :keyword]]
   :queue [:optional [:or :boolean [:enum :auto]]]
   :memory [:optional {:keep [:optional [:int {:min 1}]]}]})

(def defaults
  ``Defaults of the [:notify] slice.

  `:channels` is nil rather than a list, and nil does not mean none: it
  means *every contributed channel that delivers something* — the
  composition, read back. A list here is how a deployment delivers on
  fewer channels than it composed (a worker that mails but draws no
  bell), and how a test says `[:memory]`.``
  {:channels nil
   :queue :auto
   :memory {:keep channel/default-keep}})

(var settings
  "The [:notify] slice, resolved at :before-start."
  defaults)

(var channels
  "Every contributed channel, by name — resolved at :before-start."
  @{})

(var hook-registry
  "The running boot's hook registry (the tracking `plugin/current-boot`
  is not set on the inject path — the void/mail pose)."
  nil)

(var enqueue
  ``How a projected payload reaches a worker, or nil when this
  composition has no queue. `void/notify-jobs` installs a function
  here at :before-start; nothing else may, because "is there a queue"
  is a fact about the composition and not a thing to guess.``
  nil)

(def keeps-only
  "Channels that keep a notification rather than delivering it. In
  :prod a composition that has nothing else is a boot error."
  [:memory :log])

(def sent-hook
  "Core-hook name every receipt passes through. void/bus turns these
  into events; obs can count them."
  :void.notify/sent)

(def listeners
  "Receipt listeners registered without a manifest, by name — the
  REPL's way, and a test's."
  @{})

(defn listen!
  "Hear about every delivery without contributing a hook."
  [name f]
  (put listeners name f)
  f)

(defn unlisten!
  "Remove a listener."
  [name]
  (put listeners name nil))

(defn- emit! [receipt]
  (when-let [reg hook-registry]
    (each e (hooks/handlers reg sent-hook)
      (def [ok err] (protect ((e :fn) receipt)))
      (unless ok
        (log/warn "notify handler failed" :ns log-ns :handler (e :name) :err (log/message-of err)))))
  (each name (sorted (keys listeners))
    (when-let [f (get listeners name)]
      (def [ok err] (protect (f receipt)))
      (unless ok
        (log/warn "notify listener failed" :ns log-ns :listener name :err (log/message-of err)))))
  receipt)

# -- the channels this package ships -------------------------------------

(plugin/contribute! :void.notify/channel (channel/memory-channel))
(plugin/contribute! :void.notify/channel (channel/log-channel))

# -- which channels a notification goes out on ---------------------------

(defn delivering
  "Contributed channels that deliver somewhere — every name but the two
  the kernel ships for a test and a log."
  [&opt table]
  (default table channels)
  (sorted (filter |(not (index-of $ keeps-only)) (keys table))))

(defn active
  ``The channel names this process delivers on: `[:notify :channels]`,
  or every contributed channel that delivers something.``
  []
  (or (get settings :channels) (delivering)))

(defn channel-named
  "A contributed channel by name, or an error naming the ones there
  are — the message `[:mail :transport]` gives, in the plural."
  [name]
  (or (get channels name)
      (errorf "no notification channel %q is contributed (have %s)"
              name
              (string/join (map |(string/format "%q" $) (sorted (keys channels))) " "))))

(defn- channels-for [note]
  (def names (or (get note :channels) (active)))
  (unless (indexed? names)
    (errorf ":channels is a list of channel names, got %q" names))
  (each n names (channel-named n))
  names)

(defn queued?
  ``Will `notify/send` hand this composition's notifications to a
  queue? `[:notify :queue]` is `:auto` (yes when void/notify-jobs is
  composed), true (its absence is a boot error) or false (never).``
  []
  (case (get settings :queue :auto)
    false false
    (not (nil? enqueue))))

# -- delivering ----------------------------------------------------------

(defn deliver!
  ``Deliver one projected payload **now**, on this fiber, through the
  named channel — the primitive, and what the queued job calls on the
  worker. `notify/send` is the call an application makes.``
  [name payload]
  (def c (channel-named name))
  (def receipt ((c :deliver) payload))
  (emit! receipt)
  receipt)

(defn- dispatch [note name]
  (def c (channel-named name))
  (def [ok payload] (protect (channel/project c note)))
  (cond
    (not ok)
    (do
      (log/error "a channel could not project a notification" :ns log-ns
                 :channel name :id (note :id) :key (note :key) :err (log/message-of payload))
      {:channel name :status :failed :stage :project :error (string payload)})

    (nil? payload)
    # the notification carried no address this channel reads, or
    # nothing it is interested in: the :void.auth/deliver shape, and
    # not a failure
    {:channel name :status :skipped :why :not-addressed}

    (queued?)
    (let [[ok job] (protect (enqueue name payload))]
      (if ok
        {:channel name :status :queued :job (get job :id)}
        (do
          (log/error "a notification could not be queued" :ns log-ns
                     :channel name :id (note :id) :err (log/message-of job))
          {:channel name :status :failed :stage :queue :error (string job)})))

    (let [[ok result] (protect (deliver! name payload))]
      (if ok
        {:channel name :status :sent :receipt result}
        (do
          (log/error "a notification channel failed" :ns log-ns
                     :channel name :id (note :id) :key (note :key) :err (log/message-of result))
          {:channel name :status :failed :stage :deliver :error (string result)})))))

(defn send
  ``Send a notification on every channel it is addressed for. Returns
  what happened, per channel:

      {:id "ntf_..." :key :order/shipped :at 1756400000
       :results [{:channel :mail  :status :sent :receipt {...}}
                 {:channel :inapp :status :sent :receipt {...}}
                 {:channel :webhook :status :skipped :why :not-addressed}]}

  **One channel's failure does not take another's delivery with it.**
  Each is projected and delivered inside `protect`, and a failure is a
  `:failed` result and a log record rather than an exception — a
  webhook that times out must not swallow the letter that was going
  out beside it. With `void/notify-jobs` composed the failure is also
  a retry, because there the failing thing is a job.

  `opts` may carry `:id` and `:at`, so a test compares values rather
  than clocks.``
  [note &opt opts]
  (default opts {})
  (def names (channels-for note))
  (def normalized (notification/normalize note names opts))
  (def results (map |(dispatch normalized $) names))
  (when (empty? results)
    (log/warn "a notification went to no channel at all" :ns log-ns
              :id (normalized :id) :key (normalized :key)))
  {:id (normalized :id)
   :key (normalized :key)
   :at (normalized :at)
   :results (tuple ;results)})

(defn delivered?
  "Did at least one channel take this notification — sent it, or handed
  it to a queue? What a caller asks when it wants to know that
  something happened."
  [result]
  (truthy? (some |(index-of ($ :status) [:sent :queued]) (get result :results []))))

# -- public surface ------------------------------------------------------

(def normalize "See notification/normalize." notification/normalize)
(def summary "See notification/summary." notification/summary)
(def address-for "See notification/address-for." notification/address-for)
(def override-for "See notification/override-for." notification/override-for)
(def permanent? "See channel/permanent? — has this channel had its final answer?" channel/permanent?)

(defn outbox
  "What the :memory channel kept, oldest first."
  []
  channel/outbox)

(defn clear-outbox!
  "Empty the memory outbox — what a test does between cases."
  []
  (channel/clear!))

# -- boot ----------------------------------------------------------------

(defn- merge-slice [cfg]
  (def c (merge defaults (or cfg {})))
  (put c :memory (merge (defaults :memory) (get cfg :memory {})))
  c)

(defn- check-channels [cfg profile resolved]
  (def named (get cfg :channels))
  (when named
    (each n named
      (unless (get resolved n)
        (errorf "[:notify :channels] names %q, which no plugin contributed (have %s)"
                n
                (string/join (map |(string/format "%q" $) (sorted (keys resolved))) " ")))))
  (def names (or named (delivering resolved)))
  (when (and (= :prod profile)
             (every? (map |(truthy? (index-of $ keeps-only)) names)))
    (errorf (string "in the :prod profile this composition delivers no notification "
                    "anywhere: [:notify :channels] resolves to %s, and none of those "
                    "leaves the process. Compose :void/notify-mail, :void/notify-inapp "
                    "or :void/notify-webhook — or a channel of the application's own")
            (if (empty? names)
              "nothing"
              (string/join (map |(string/format "%q" $) names) " ")))))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :notify/configure
   :doc "Resolve the [:notify] slice and the channels this process delivers on"
   :fn (fn configure [boot]
         (set hook-registry (get boot :hooks))
         (def resolved (or (get-in boot [:extensions :void.notify/channel :resolved]) @{}))
         (def cfg (merge-slice (get-in boot [:config :values :notify])))
         (check-channels cfg (get boot :profile :dev) resolved)
         (set channels resolved)
         (set settings cfg)
         (set channel/keep-count (get-in cfg [:memory :keep] channel/default-keep))
         (log/info "notify ready" :ns log-ns
                   :channels (sorted (keys resolved))
                   :active (active)))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 300
   :name :notify/queue-check
   :doc "Refuse a composition that asked for queued notifications and has no queue"
   :fn (fn queue-check [_]
         (when (and (true? (get settings :queue)) (nil? enqueue))
           (error (string "[:notify :queue] is true and this composition has no "
                          "notification queue — add :void/notify-jobs (and void/jobs "
                          "under it), or set [:notify :queue] false to deliver on the "
                          "calling fiber"))))})

# -- CLI -----------------------------------------------------------------

(defn print-status
  "What this process will do with a notification — the body of `void
  notify status`."
  []
  (printf "channels   %s"
          (string/join (map |(string/format "%q" $) (sorted (keys channels))) " "))
  (printf "active     %s"
          (let [names (active)]
            (if (empty? names)
              "(none — nothing this composition sends leaves the process)"
              (string/join (map |(string/format "%q" $) names) " "))))
  (each name (active)
    (def c (get channels name))
    (printf "  %q%s%s" name
            (if-let [a (get c :address)] (string/format "  <- :to %q" a) "")
            (if-let [d (get c :doc)] (string " — " d) "")))
  (printf "queue      %s"
          (cond
            (queued?) "yes — every channel's payload is handed to void/jobs"
            (true? (get settings :queue)) "asked for, and this composition has none"
            "no — delivered on the calling fiber")))

(plugin/contribute! :void.core/cli
  {:name :notify/status
   :read-only? true
   :doc "Show the channels a notification goes out on: void notify status"
   :fn (fn cli-status [& args]
         (unless (empty? args)
           (errorf "void notify status takes no arguments (got %q)" (string/join args " ")))
         (print-status))})

(plugin/contribute! :void.core/cli
  {:name :notify/send
   :read-only? false
   :doc "Send a test notification to an address: void notify send <address>"
   :fn (fn cli-send [& args]
         (unless (= 1 (length args))
           (error "usage: void notify send <address>"))
         (def to (first args))
         (def result
           (send {:key :notify/test
                  :title "void notify send"
                  :body (string "This is `void notify send`, delivered at "
                                (os/time) ".")
                  # one address, every active channel: whichever of them
                  # reads it delivers, and the rest report themselves
                  # skipped — which is the answer the operator wanted
                  :to {:email to :subject to :url to}}))
         (printf "notification %s" (result :id))
         (each r (result :results)
           (printf "  %q %q%s" (r :channel) (r :status)
                   (if-let [e (get r :error)] (string " — " e) ""))))})

(plugin/contribute! :void.core/cli
  {:name :notify/outbox
   :read-only? true
   :doc "Print what the :memory channel kept: void notify outbox"
   :fn (fn cli-outbox [& args]
         (unless (empty? args)
           (errorf "void notify outbox takes no arguments (got %q)" (string/join args " ")))
         (if (empty? (outbox))
           (print "the outbox is empty")
           (each n (outbox) (print (notification/summary n)))))})

(plugin/contribute! :void.core/health
  {:name :notify/channels
   :fn (fn notify-health []
         (def parts
           (tabseq [name :in (active)
                    :let [c (get channels name)
                          h (get c :health)
                          # a channel whose own check threw says so here
                          # rather than taking the health endpoint down
                          [ok answer] (if h (protect (h)) [true nil])]
                    :when h]
             name (if ok answer {:status :down :error (string answer)})))
         (merge {:status :up
                 :channels (active)
                 :queued (queued?)}
                (if (empty? parts) {} {:detail parts})))})

(plugin/defplugin void/notify
  :doc "One notification, several channels: a notification is a table, a channel is a contribution (:memory and :log here, mail/in-app/webhook in the plugins beside it), projection happens where send was called and delivery where the network is — so a queue fits between them — and in production a composition that delivers nowhere is a boot error."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :hooks [sent-hook]
  :config-key :notify
  :config-schema Config
  :config-defaults defaults)
