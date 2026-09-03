### void/mail/transport — what a delivery is handed to.
###
### A transport is a **contribution**, not a component: `{:name :send
### (fn [delivery] receipt)}` on the `:void.mail/transport` point, and
### `[:mail :transport]` names the one this process uses. That is the
### shape `void/html` gives view engines, for the same reason — a
### transport has no state worth starting, and the alternative
### (a component providing an interface, the way `:void/cache-store`
### does) would make "which one" an ambiguity the kernel refuses to
### resolve, when here it is simply a name in the config.
###
### A **delivery** is what `mail/send` builds and hands over:
###
###     {:message <normalized message>   the data (./message)
###      :bytes   "Date: ...\r\n..."     the same thing as octets (./mime)
###      :id      "<abc@example.com>"    its Message-ID
###      :at      1756400000}
###
### Both halves travel together on purpose: SMTP needs the octets and
### the envelope, a test wants the fields, and rendering twice would
### mean two Message-IDs for one mail.
###
### A **receipt** comes back: `{:transport :accepted :rejected :id}`.
### `:rejected` carries the recipients the server refused *by name*,
### because "some of it went" is the normal outcome of a multi-
### recipient mail and a boolean cannot say it.
###
### Two transports live here — the two that need no network. `:smtp`
### is in ./smtp, and anything else (a provider's HTTP API) is an
### application's contribution to the same point.

(import void/core/log :as log)
(import ./message :as message)

(def log-ns "void.mail")

(defn receipt
  "The value a transport returns: what was accepted, what was refused
  and by whom."
  [name delivery &opt parts]
  (default parts {})
  (merge {:transport name
          :id (delivery :id)
          :accepted (get parts :accepted (get-in delivery [:message :recipients] []))
          :rejected (get parts :rejected [])
          :at (get delivery :at (os/time))}
         parts))

(defn normalize
  ``Check a `:void.mail/transport` contribution and fill in what it did
  not say. Runs at boot, so a transport that cannot send anything is a
  start error rather than a mail that disappears.``
  [t]
  (unless (dictionary? t)
    (errorf "a transport is a table {:name :send}, got %q" t))
  (unless (keyword? (get t :name))
    (errorf "a transport needs a keyword :name, got %q" (get t :name)))
  (unless (function? (get t :send))
    (errorf "transport %q has no :send function" (get t :name)))
  (merge {:doc nil :health nil} t))

# -- :memory — the outbox a test reads -----------------------------------

(var outbox
  ``Deliveries the :memory transport kept, newest last. A test asserts
  on this; `void mail outbox` prints it.``
  @[])

(def default-keep
  "How many deliveries the memory transport holds on to. A queue that
  grew without a bound would be a leak in the one process type that
  must not have one — a long-running dev server."
  100)

(var keep-count default-keep)

(defn clear!
  "Empty the memory outbox."
  []
  (set outbox @[])
  nil)

(defn memory-transport
  "The transport that delivers into `outbox` — the default, and what a
  test suite runs on."
  []
  {:name :memory
   :doc "Keep deliveries in memory; mail/outbox reads them back"
   :send (fn memory-send [delivery]
           (array/push outbox delivery)
           (when (> (length outbox) keep-count)
             (set outbox (array/slice outbox (- (length outbox) keep-count))))
           (receipt :memory delivery))})

# -- :file — one .eml per message ----------------------------------------

(defn- ensure-dir [path]
  (def parts (filter |(not (empty? $)) (string/split "/" path)))
  (var acc (if (string/has-prefix? "/" path) "/" ""))
  (each p parts
    (set acc (string acc p "/"))
    (unless (os/stat acc :mode) (os/mkdir acc)))
  path)

(defn- safe-id [delivery]
  (def id (string (get delivery :id "message")))
  (string/replace-all "/" "_"
    (string/replace-all "<" "" (string/replace-all ">" "" id))))

(defn file-transport
  ``The transport that writes each mail into a directory as a `.eml`
  file — the dev default in every framework that has one, because a
  .eml opens in a mail client and answers "what did it actually look
  like" without a server anywhere.``
  [dir]
  {:name :file
   :doc (string "Write each message into " dir " as a .eml file")
   :send (fn file-send [delivery]
           (ensure-dir dir)
           (def path (string dir "/" (get delivery :at (os/time)) "-" (safe-id delivery) ".eml"))
           (with [f (file/open path :wn)]
             (file/write f (delivery :bytes)))
           (log/info "mail written" :ns log-ns
                     :path path :to (get-in delivery [:message :recipients]))
           (receipt :file delivery {:path path}))})

# -- :log — the message in the log, and nowhere else ---------------------

(defn log-transport
  "The transport that logs a message instead of sending it."
  []
  {:name :log
   :doc "Log the message; deliver it nowhere"
   :send (fn log-send [delivery]
           (log/info "mail (not sent)" :ns log-ns
                     :summary (message/summary (delivery :message))
                     :body (delivery :bytes))
           (receipt :log delivery))})
