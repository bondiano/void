### void/mail — mail as data, delivery as a composition decision.
###
### The shape of this package is one sentence: **a message is data, a
### body is a void/html view, a transport is a contribution, and
### whether a mail goes out on this fiber or through a queue is
### decided by what the application composed — not by which function
### it called.**
###
###     (import void/mail :as mail)
###
###     (mail/send {:to (user :email)
###                 :subject "Your sign-in link"
###                 :view [:p [:a {:href (mail/url "/magic")} "Sign in"]]})
###
### That call renders the view through the engine `void/html` already
### selected, fills in `:from`, the subject prefix and the headers from
### `[:mail]`, mints a Message-ID and a Date, projects the whole thing
### to RFC 5322 octets, and hands the result to the transport named by
### `[:mail :transport]`. With `void/mail-jobs` composed it hands it to
### `void/jobs` instead, and the same delivery goes out on a worker —
### the call site does not change, because "does this deployment have
### a worker" is not something a call site knows.
###
### Four plugins' worth of composition, three of which are here:
###
###     :void/mail        the mailer (this file)
###     :void/mail-jobs   delivery through void/jobs (./jobs)
###     :void/mail-auth   magic links and one-time codes (./auth)
###
### Transports: `:memory` (a test's outbox), `:file` (one .eml per
### message — the dev default), `:log`, `:smtp` (./smtp) and whatever
### an application contributes to `:void.mail/transport`. **In the
### :prod profile a transport that delivers nowhere is a boot error**,
### for the reason void/security refuses to invent a signing key in
### production: a deployment that silently mails nothing looks exactly
### like a deployment that works.
###
### What is deliberately not here: TLS of our own (a relay next to the
### application remains the default; with `:void/tls` composed, [:mail
### :smtp :tls] turns on STARTTLS or smtps), IMAP/POP, and a connection
### pool (see ./smtp).

(import void/core/plugin :as plugin)
(import void/core/config :as config)
(import void/core/hooks :as hooks)
(import void/core/log :as log)
(import ./address :as address)
(import ./message :as message)
(import ./mime :as mime)
(import ./render :as render)
(import ./smtp :as smtp)
(import ./transport :as transport)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.mail")

# -- extension point -----------------------------------------------------

(plugin/defextension-point :void.mail/transport
  :doc "Mail transports: {:name :smtp :send (fn [delivery] receipt) :doc string?}; [:mail :transport] names the one this process uses. A delivery is {:message :bytes :id :at}; a receipt is {:transport :id :accepted :rejected}"
  :schema {:name :keyword
           :doc [:optional :string]
           :send :function
           :health [:optional :function]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate mail transport %q" (c :name)))
                (put seen (c :name) true)))
  :reduce (fn [contribs] (tabseq [c :in contribs] (c :name) (transport/normalize c))))

(plugin/contribute! :void.core/interface
  {:name :void/mail
   :doc "The resolved mailer: the transports this composition has, the one it sends through and the [:mail] slice behind them."
   :methods {:transport "the active transport's name"
             :transports "every contributed transport, by name"
             :settings "the [:mail] slice as it was resolved"}})

# -- config --------------------------------------------------------------

(def SmtpConfig
  "Schema of the [:mail :smtp] slice."
  {:host [:optional :string]
   :port [:optional [:int {:min 1 :max 65535}]]
   :username [:optional :string]
   :password [:optional :any]
   :auth [:optional [:enum :auto :plain :login :none]]
   :helo [:optional :string]
   :tls [:optional [:enum :none :starttls :smtps]]
   :timeout [:optional [:number {:min 0.001}]]
   :connect-timeout [:optional [:number {:min 0.001}]]
   :allow-plaintext-auth [:optional :boolean]})

(def Config
  "Schema of the [:mail] config slice."
  {:transport [:optional :keyword]
   :from [:optional :any]
   :reply-to [:optional :any]
   :envelope-from [:optional :any]
   :subject-prefix [:optional :string]
   :headers [:optional :dictionary]
   :to-override [:optional :string]
   :base-url [:optional :string]
   :queue [:optional [:or :boolean [:enum :auto]]]
   :smtp [:optional SmtpConfig]
   :file [:optional {:dir [:optional :string]}]
   :memory [:optional {:keep [:optional [:int {:min 1}]]}]})

(def defaults
  ``Defaults of the [:mail] slice.

  `:transport :file` writes every message into `tmp/mail` as a .eml —
  visible, openable in a mail client, and impossible to mistake for
  delivery. It is the dev default and a **boot error in prod**, which
  is the whole reason it can be the default at all.

  There is no default `:from`: see ./message.``
  {:transport :file
   :from nil
   :reply-to nil
   :envelope-from nil
   :subject-prefix nil
   :headers {}
   :to-override nil
   :base-url nil
   :queue :auto
   :smtp smtp/defaults
   :file {:dir "tmp/mail"}
   :memory {:keep transport/default-keep}})

(var settings
  "The [:mail] slice, resolved at :before-start."
  defaults)

(var transports
  "Every contributed transport, by name — resolved at :before-start."
  @{})

(var hook-registry
  "The running boot's hook registry (the tracking `plugin/current-boot`
  is not set on the inject path — see void/auth's init)."
  nil)

(var enqueue
  ``How a message reaches a worker, or nil when this composition has
  no queue. `void/mail-jobs` installs a function here at :before-start;
  nothing else may, because "is there a queue" is a fact about the
  composition and not a thing to guess.``
  nil)

(def sent-hook
  "Core-hook name every receipt passes through. void/bus turns
  these into events; obs can count them."
  :void.mail/sent)

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
        (log/warn "mail handler failed" :ns log-ns :handler (e :name) :err (string err)))))
  (each name (sorted (keys listeners))
    (when-let [f (get listeners name)]
      (def [ok err] (protect (f receipt)))
      (unless ok
        (log/warn "mail listener failed" :ns log-ns :listener name :err (string err)))))
  receipt)

# -- the transports this package ships -----------------------------------

(defn- file-dir [] (get-in settings [:file :dir] "tmp/mail"))

(plugin/contribute! :void.mail/transport
  # built lazily so that [:mail :file :dir] changed from a REPL is
  # where the next mail lands
  {:name :file
   :doc "Write each message into [:mail :file :dir] as a .eml file"
   :send (fn file-send [delivery]
           (((transport/file-transport (file-dir)) :send) delivery))})

(plugin/contribute! :void.mail/transport (transport/memory-transport))
(plugin/contribute! :void.mail/transport (transport/log-transport))
(plugin/contribute! :void.mail/transport (smtp/transport (fn [] (get settings :smtp {}))))

# -- building a delivery -------------------------------------------------

(defn- token [n]
  (string/join (map |(string/format "%02x" $) (os/cryptorand n)) ""))

(defn build
  ``A message, resolved into the delivery a transport receives:

      {:message <normalized>  :bytes <RFC 5322>  :id <Message-ID>  :at <time>}

  Pure but for the clock and the randomness that name the message, and
  both can be handed in (`:at`, `:id`, `:boundaries`) so that a test
  compares bytes.``
  [msg &opt opts]
  (default opts {})
  (def rendered (render/render-message msg))
  (def normalized (message/normalize rendered settings))
  (def at (get opts :at (os/time)))
  (def id (or (get opts :id)
              (mime/message-id (token 12) (address/domain-of (normalized :from)))))
  {:message normalized
   :bytes (mime/render normalized {:date at
                                   :message-id id
                                   :boundaries (get opts :boundaries
                                                    [(token 8) (token 8)])})
   :id id
   :at at})

(defn active-transport
  "The transport this process sends through."
  []
  (def name (get settings :transport :file))
  (or (get transports name)
      (errorf "[:mail :transport] names %q, which no plugin contributed (have %s)"
              name
              (string/join (map |(string/format "%q" $) (sorted (keys transports))) " "))))

(defn deliver!
  ``Send a delivery **now**, on this fiber, through the active
  transport — the primitive, and what the queued job calls on the
  worker. `mail/send` is the call an application makes.

  Takes a delivery from `build` or a message, which it builds first.``
  [delivery-or-message]
  (def delivery
    (if (message/normalized? (get delivery-or-message :message))
      delivery-or-message
      (build delivery-or-message)))
  (def t (active-transport))
  (def receipt ((t :send) delivery))
  (emit! receipt)
  receipt)

(defn queued?
  ``Will `mail/send` hand this composition's mail to a queue?
  `[:mail :queue]` is `:auto` (yes when void/mail-jobs is composed),
  true (yes, and its absence is a boot error) or false (never).``
  []
  (case (get settings :queue :auto)
    false false
    (not (nil? enqueue))))

(defn send-delivery
  ``Send a delivery that is already built, applying this composition's
  queue decision — the second half of `send`, and what a caller with a
  rendered letter in hand calls directly (void/notify's mail channel,
  which rendered it where the request was, and a retry of one that was
  kept).

  Rendering happened once, wherever it happened; this is only the
  routing.``
  [delivery]
  (if (queued?)
    (let [job (enqueue delivery)]
      (log/debug "mail queued" :ns log-ns
                 :id (delivery :id) :to (get-in delivery [:message :recipients]))
      (transport/receipt :queue delivery {:queued true :job (get job :id)}))
    (deliver! delivery)))

(defn send
  ``Send a message. With a queue in the composition it is rendered
  here — so that what the worker sends is what this request meant,
  claims, locale and all — and delivered there; without one it goes
  out on this fiber.

  Returns a receipt. A queued one carries `:queued true` and the job's
  id; both carry the Message-ID, so a caller can log the same thing
  either way. The `:void.mail/sent` hook fires where the letter is
  actually delivered — on the worker, for a queued one — because that
  is the event, and "handed to a queue" is not it.``
  [msg &opt opts]
  (send-delivery (build msg opts)))

# -- public surface ------------------------------------------------------

(def url "See render/url — an absolute URL for a link in a letter." render/url)
(def asset "See render/asset." render/asset)
(def render-view "See render/render." render/render)
(def normalize "See message/normalize." message/normalize)
(def text-of "See mime/text-of — the plain-text projection of an HTML body." mime/text-of)
(def parse-address "See address/parse." address/parse)
(def permanent-failure? "See smtp/permanent? — did the server give its final answer?" smtp/permanent?)

(defn outbox
  "What the :memory transport kept, oldest first."
  []
  transport/outbox)

(defn clear-outbox!
  "Empty the memory outbox — what a test does between cases."
  []
  (transport/clear!))

(defn preview
  "The octets a message would go out as, without sending it — what a
  REPL and a snapshot test look at."
  [msg &opt opts]
  ((build msg opts) :bytes))

# -- boot ----------------------------------------------------------------

(defn- merge-slice [cfg]
  (def c (merge defaults (or cfg {})))
  (each key [:smtp :file :memory]
    (put c key (merge (defaults key) (get cfg key {}))))
  c)

(def deliver-nowhere
  "Transports that keep a message rather than send it. In :prod each
  of them is a boot error."
  [:memory :file :log])

(defn- check-transport [cfg profile]
  (def name (get cfg :transport :file))
  (unless (get transports name)
    (errorf "[:mail :transport] names %q, which no plugin contributed (have %s)"
            name
            (string/join (map |(string/format "%q" $) (sorted (keys transports))) " ")))
  (when (= :smtp name)
    # a TLS mode without void/tls, or a password that would go out in
    # the clear — both misconfigurations, and boot is where finding
    # them costs nothing (./smtp)
    (when-let [why (smtp/tls-refusal (get cfg :smtp {}))] (error why))
    (when-let [why (smtp/auth-refusal (get cfg :smtp {}))] (error why)))
  (when (and (= :prod profile) (index-of name deliver-nowhere))
    (errorf (string "[:mail :transport] is %q in the :prod profile, and %q does not "
                    "send mail — it keeps it. Point [:mail :transport] at :smtp (a "
                    "relay this process can reach) or at a transport this application "
                    "contributed")
            name name)))

(defn- reveal-password [cfg]
  (def p (get-in cfg [:smtp :password]))
  (when (config/secret? p)
    (put (cfg :smtp) :password (config/reveal p)))
  cfg)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :mail/configure
   :doc "Resolve the [:mail] slice, the transports and the base URL letters link against"
   :fn (fn configure [boot]
         (set hook-registry (get boot :hooks))
         (set transports (or (get-in boot [:extensions :void.mail/transport :resolved]) @{}))
         (def cfg (reveal-password (merge-slice (get-in boot [:config :values :mail]))))
         (check-transport cfg (get boot :profile :dev))
         (set settings cfg)
         (set render/base-url (get cfg :base-url))
         (set transport/keep-count (get-in cfg [:memory :keep] transport/default-keep))
         (log/info "mail ready" :ns log-ns
                   :transport (cfg :transport)
                   :from (when-let [f (cfg :from)] ((address/parse f) :email))
                   :base-url (cfg :base-url)
                   :transports (sorted (keys transports))))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 300
   :name :mail/queue-check
   :doc "Refuse a composition that asked for queued mail and has no queue"
   :fn (fn queue-check [_]
         (when (and (true? (get settings :queue)) (nil? enqueue))
           (error (string "[:mail :queue] is true and this composition has no mail "
                          "queue — add :void/mail-jobs (and void/jobs under it), or "
                          "set [:mail :queue] false to send on the request fiber"))))})

# -- CLI -----------------------------------------------------------------

(defn print-status
  "What this process will do with a message — the body of `void mail
  status`."
  []
  (def t (active-transport))
  (printf "transport  %q%s" (t :name) (if-let [d (t :doc)] (string " — " d) ""))
  (printf "available  %s"
          (string/join (map |(string/format "%q" $) (sorted (keys transports))) " "))
  (printf "from       %s" (or (when-let [f (settings :from)] (address/format-address f))
                              "(unset — every message must carry its own :from)"))
  (printf "base-url   %s" (or (settings :base-url)
                              "(unset — mail/url will refuse to build a link)"))
  (printf "queue      %s"
          (cond
            (queued?) "yes — the letter is handed to void/jobs"
            (true? (get settings :queue)) "asked for, and this composition has none"
            "no — sent on the calling fiber"))
  (when (= :smtp (t :name))
    (def s (settings :smtp))
    (printf "smtp       %s:%d auth=%q%s"
            (get s :host) (get s :port) (get s :auth)
            (if (get s :username) (string " user=" (get s :username)) "")))
  (when (= :file (t :name))
    (printf "directory  %s" (file-dir)))
  (when (settings :to-override)
    (printf "override   every recipient is replaced by %s" (settings :to-override))))

(plugin/contribute! :void.core/cli
  {:name :mail/status
   :read-only? true
   :doc "Show the transport, the sender and where mail goes: void mail status"
   :fn (fn cli-status [& args]
         (unless (empty? args)
           (errorf "void mail status takes no arguments (got %q)" (string/join args " ")))
         (print-status))})

(plugin/contribute! :void.core/cli
  {:name :mail/send
   :read-only? false
   :doc "Send a test message through the configured transport: void mail send <address>"
   :fn (fn cli-send [& args]
         (unless (= 1 (length args))
           (error "usage: void mail send <address>"))
         (def receipt
           (deliver! {:to (first args)
                      :subject "void mail send"
                      :text (string "This is `void mail send`, sent through the "
                                    (string (get settings :transport))
                                    " transport at "
                                    (mime/date-header (os/time)) ".\n")}))
         (printf "sent %s through %q" (receipt :id) (receipt :transport))
         (each r (get receipt :rejected [])
           (printf "  refused: %s — %s" (r :email) (r :message))))})

(plugin/contribute! :void.core/cli
  {:name :mail/outbox
   :read-only? true
   :doc "Print what the :memory transport kept: void mail outbox"
   :fn (fn cli-outbox [& args]
         (unless (empty? args)
           (errorf "void mail outbox takes no arguments (got %q)" (string/join args " ")))
         (if (empty? (outbox))
           (print "the outbox is empty")
           (each d (outbox)
             (printf "%s  %s" (d :id) (message/summary (d :message))))))})

(plugin/contribute! :void.core/health
  {:name :mail/transport
   :fn (fn mail-health []
         (def t (active-transport))
         (merge {:status :up
                 :transport (t :name)
                 :queued (queued?)}
                (if-let [h (t :health)] (h) {})))})

(plugin/defplugin void/mail
  :doc "Mail as data: a message is a table, a body is a void/html view rendered by the engine the composition already selected, a transport is a contribution (:memory, :file, :log, :smtp or an application's own), and a transport that keeps mail rather than sending it is a boot error in production."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/html ">=0.0.1"}
  :hooks [sent-hook]
  :config-key :mail
  :config-schema Config
  :config-defaults defaults)
