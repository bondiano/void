### void/bus — messaging: a message is data, a guarantee is declared
### (SPEC.md §5.22, ADR-0012, ROADMAP 3.6).
###
### The shape of this package is one sentence: **a message is a plain
### table on a keyword topic, what happens to it when a handler throws
### is the backend's declared guarantee and never a hidden default,
### and the only sanctioned way to announce what a transaction wrote
### is the outbox.**
###
###     (import void/bus :as bus)
###
###     (bus/publish :user/created {:id 42 :email addr})
###
###     (bus/defhandler index-user {:topic :user/created} [msg]
###       (search/index (msg :payload)))
###
### **Why this is not void/jobs, and not void/core/hooks.** Three
### mechanisms, three semantics (ADR-0012), and picking between them
### is a sentence, not a table:
###
###   `void/core/hooks`  "call these functions now" — synchronous,
###                      in-process, part of the bootstrap wiring
###   `void/jobs`        "do this piece of work, and confirm it" —
###                      one owner, retries, priorities, a dead letter
###                      queue. The work is the subject
###   `void/bus`         "this happened" — many consumers, ordering per
###                      group, at-least-once where the backend says
###                      so. The *fact* is the subject, and who cares
###                      about it is not the publisher's business
###
### A handler that has to do something slow publishes nothing and
### enqueues a job: the two layers compose, and `void/bus-jobs` makes
### the traffic go the other way too, forwarding the queue's own
### lifecycle events onto the bus.
###
### Four plugins' worth of composition, three of which are here:
###
###     :void/bus       the broker, the router, the in-process backend
###     :void/bus-db    the durable log, the cursors and the outbox
###     :void/bus-jobs  void/jobs's lifecycle events on the bus
###
### Backends are contributions to `:void.bus/backend` and `[:bus
### :backend]` names the one this process speaks — `:memory` here,
### `:db` in ./db. Codecs are contributions to `:void.bus/codec` and
### `[:bus :codec]` names one: `:json` by default, because a message
### is a contract with consumers that are, sooner or later, other
### processes in other languages (see ./codec on why the codec runs
### even under the in-process backend).
###
###     (void/run! {:plugins [:void/db :void/db-postgres
###                           :void/bus :void/bus-db ...]})
###     # config/prod.janet — the web process, which publishes
###     {:bus {:backend :db :codec :json :consume false}}
###     # config/worker.janet — the process started by `void bus consume`
###     {:bus {:backend :db :group :billing}}

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./backend :as backend)
(import ./codec :as codec)
(import ./cqrs :as cqrs)
(import ./memory :as memory)
(import ./message :as message)
(import ./middleware :as middleware)
(import ./router :as router)
(import ./state :as state)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.bus")

# -- the interface -------------------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/bus
   :doc "The broker: the backend this process speaks, the codec its messages travel in, the middleware chain and the consumers it started. Depend on the interface rather than the key to let a test stand a bus of its own in its place."
   :methods {:backend "the backend underneath, with its declared guarantees"
             :codec "the codec messages are encoded with"
             :group "the consumer group handlers join when they name none"
             :consumers "the groups this process is consuming"}})

# -- extension points ----------------------------------------------------

(defn- unique-names! [what contribs]
  (def seen @{})
  (each c contribs
    (when (in seen (c :name))
      (errorf "duplicate %s %q" what (c :name)))
    (put seen (c :name) true)))

(plugin/defextension-point :void.bus/backend
  :doc "Message-bus backends (ADR-0012): {:name :db :make (fn [bus-config] backend) :doc string?}; [:bus :backend] names the one this process speaks. A backend declares its guarantees ({:delivery :at-most-once|:at-least-once :ordering :none|:per-group :durable :shared}) and the router reads them — see void/bus/backend"
  :schema {:name :keyword
           :doc [:optional :string]
           :make :function}
  :validate (fn [contribs] (unique-names! "bus backend" contribs))
  :reduce (fn [contribs]
            (tabseq [c :in contribs] (c :name) (backend/normalize-factory c))))

(plugin/defextension-point :void.bus/codec
  :doc "Message codecs: {:name :json :encode (fn [value] bytes) :decode (fn [bytes] value) :bytes? boolean?}; [:bus :codec] picks one by name. :bytes? false means the codec does not produce bytes at all (:raw), which a backend that stores them refuses at start"
  :schema {:name :keyword
           :doc [:optional :string]
           :encode :function
           :decode :function
           :bytes? [:optional :boolean]}
  :validate (fn [contribs] (unique-names! "bus codec" contribs))
  :reduce (fn [contribs] (tabseq [c :in contribs] (c :name) (codec/normalize c))))

(plugin/defextension-point :void.bus/middleware
  :doc "Message middleware: {:name :phase :wrap (fn [handler handler-opts] handler') :named boolean? :when (fn [handler-opts] bool)?}; the same phase scale as :void.http/middleware, and the handler's own options as a second argument because a bus handler's options are fixed at declaration (see void/bus/middleware). A :named contribution applies only to handlers that list it under :middleware"
  :schema {:name :keyword
           :doc [:optional :string]
           :phase [:optional :number]
           :wrap :function
           :named [:optional :boolean]
           :when [:optional :function]}
  :validate (fn [contribs] (unique-names! "bus middleware" contribs))
  :reduce (fn [contribs] (tuple ;(map middleware/normalize contribs))))

(each c codec/builtin (plugin/contribute! :void.bus/codec c))

# -- config --------------------------------------------------------------

(def Retry
  "Schema of the [:bus :retry] slice."
  {:enabled [:optional :boolean]
   :attempts [:optional [:int {:min 1}]]
   :strategy [:optional [:enum :fixed :linear :exponential]]
   :base [:optional [:number {:min 0}]]
   :max [:optional [:number {:min 0}]]
   :jitter [:optional [:number {:min 0 :max 1}]]})

(def Config
  "Schema of the [:bus] config slice."
  {:backend [:optional :keyword]
   :codec [:optional :keyword]
   # the consumer group the handlers that name none belong to. One per
   # deployable service: two processes of the same service share it and
   # split the log, two services use two and both see everything
   :group [:optional :keyword]
   :consume [:optional :boolean]
   :retry [:optional Retry]
   :poison [:optional {:enabled [:optional :boolean]
                       :max-attempts [:optional [:int {:min 1}]]
                       :topic [:optional :keyword]}]
   :dedup [:optional {:enabled [:optional :boolean]
                      :window [:optional [:number {:min 0}]]}]
   :throttle [:optional {:max [:optional [:int {:min 0}]]
                         :window [:optional [:number {:min 0.001}]]}]
   :memory [:optional {:buffer [:optional [:int {:min 1}]]
                       :keep [:optional [:int {:min 0}]]}]})

(def defaults
  ``Defaults of the [:bus] slice.

  `:backend :memory` and `:codec :json` are the two that decide what
  this plugin *is* out of the box: messages that never leave the
  process, in the shape they would have if they did. The first is a
  default because a monolith is where every application starts; the
  second is a default because the day the monolith stops being one,
  nothing about the payloads changes.

  `:consume true` means a process consumes what its own `defhandler`s
  declare. A process that must not — a web tier that imports the
  handler modules for their side effects, a migration run — says so in
  one line.``
  {:backend :memory
   :codec :json
   :group :default
   :consume true
   :retry {:attempts 3 :strategy :exponential :base 0.2 :max 30 :jitter 0.25}
   :poison {:enabled true :max-attempts 5 :topic :bus/poison}
   :dedup {:enabled true :window 300}
   :throttle {:max 0 :window 1}
   :memory memory/defaults})

(defn- slice [cfg0]
  (def cfg (merge @{} defaults (or cfg0 {})))
  (each k [:retry :poison :dedup :throttle :memory]
    (put cfg k (merge @{} (defaults k) (get (or cfg0 {}) k {}))))
  cfg)

# -- public surface (re-exports) -----------------------------------------

(def Backend "See backend/normalize — the backend contract." backend/normalize)
(def backend-capabilities "See backend/capabilities — what a backend promises." backend/capabilities)
(def at-least-once? "See backend/at-least-once?." backend/at-least-once?)
(def durable? "See backend/durable?." backend/durable?)

(def Codec "See codec/normalize." codec/normalize)
(def codecs "See codec/builtin — the codecs this plugin ships." codec/builtin)
(def find-codec "See codec/find-codec." codec/find-codec)

(def make-message "See message/make — normalize a message." message/make)
(def message? "See message/message?." message/message?)
(def new-id "See message/new-id — a sortable message id." message/new-id)
(def correlation-id "See message/correlation-id." message/correlation-id)
(def correlation-dyn "See message/correlation-dyn — the correlation every message published on this fiber inherits." message/correlation-dyn)
(def causation-dyn "See message/causation-dyn." message/causation-dyn)
(def redelivery "See message/redelivery — how often this message has been handed over before." message/redelivery)
(def with-meta "See message/with-meta." message/with-meta)
(def message-summary "See message/summary — one line for a listing." message/summary)
(def topic-matches? "See message/matches? — does a topic match a subscription pattern?" message/matches?)
(def message-fields "See message/fields." message/fields)

(def phases "See middleware/phases — the phase constants, which are void/http's." middleware/phases)
(def phase/panic-guard middleware/phase/panic-guard)
(def phase/observability middleware/phase/observability)
(def phase/poison middleware/phase/poison)
(def phase/retry middleware/phase/retry)
(def phase/dedup middleware/phase/dedup)
(def phase/throttle middleware/phase/throttle)
(def phase/validation middleware/phase/validation)
(def phase/business middleware/phase/business)
(def phase/response middleware/phase/response)

(def define-handler! "See router/define! — the runtime half of defhandler." router/define!)
(def handlers "See router/defined — names of every declared handler." router/defined)
(def handler-of "See router/lookup — the definition behind a name." router/lookup)
(def forget-handler! "See router/forget!." router/forget!)
(def handler-fn "See router/handler-fn — the function behind a definition, resolved now." router/handler-fn)
(def handler-groups "See router/groups — every consumer group the handlers ask for." router/groups)

(defmacro defhandler
  ``Subscribe a function to a topic (see void/bus/router):

      (bus/defhandler order-paid
        "Ship what was paid for."
        {:topic :order/paid}
        [msg]
        (shipping/schedule (get-in msg [:payload "order_id"])))``
  [name & more]
  (router/defhandler-form name more))

# -- CQRS (see ./cqrs — an optional layer, and a thin one) ---------------

(def define-event! "See cqrs/define-event! — the runtime half of defevent." cqrs/define-event!)
(def event-of "See cqrs/event — the declaration behind an event name." cqrs/event)
(def events "See cqrs/declared-events." cqrs/declared-events)
(def forget-event! "See cqrs/forget-event!." cqrs/forget-event!)
(def emit! "See cqrs/emit! — publish a declared event, schema checked." cqrs/emit!)
(def emit-tx! "See cqrs/emit-tx! — the same, through the outbox." cqrs/emit-tx!)

(def define-command! "See cqrs/define-command! — the runtime half of defcommand." cqrs/define-command!)
(def command-of "See cqrs/command." cqrs/command)
(def commands "See cqrs/declared-commands." cqrs/declared-commands)
(def forget-command! "See cqrs/forget-command!." cqrs/forget-command!)
(def send "See cqrs/send — dispatch a command to its one handler, here, and return what it returned." cqrs/send)

(defmacro defevent
  ``Declare an event — its topic and the shape of its payload (see
  void/bus/cqrs):

      (bus/defevent account-debited
        {:topic :account/debited
         :schema {:account :string :amount :number}})``
  [name & more]
  (cqrs/defevent-form name more))

(defmacro defevent-handler
  ``Handle a declared event, taking its topic and schema from the
  declaration (see void/bus/cqrs):

      (bus/defevent-handler notify-customer
        {:event :account-debited}
        [msg]
        (mail/send (msg :payload)))``
  [name & more]
  (cqrs/defevent-handler-form name more))

(defmacro defcommand
  ``Declare the one handler of a command (see void/bus/cqrs):

      (bus/defcommand debit-account
        {:schema {:account :string :amount [:number {:min 0}]}}
        [cmd]
        (accounts/debit! (cmd :account) (cmd :amount)))``
  [name & more]
  (cqrs/defcommand-form name more))

(def broker-dyn "See state/broker-dyn — the broker override." state/broker-dyn)
(def active-broker "See state/active." state/active)
(def active-backend "See state/active-backend." state/active-backend)
(def make-broker "See state/make — a broker value without a bootstrap." state/make)
(def envelope "See state/envelope — a message through the codec." state/envelope)
(def hydrate "See state/hydrate — an envelope back into a message." state/hydrate)

(def publish "See state/publish — publish a message." state/publish)
(def publish-tx! "See state/publish-tx! — publish through the transactional outbox." state/publish-tx!)
(def outbox-writer "See state/outbox-writer — the outbox writer in force, or nil." state/outbox-writer)
(def capabilities "See state/capabilities — what this backend promises." state/capabilities)
(def stats "See state/stats." state/stats)
(def start-consumers! "See state/start-consumers!." state/start-consumers!)
(def stop-consumers! "See state/stop-consumers!." state/stop-consumers!)

(var memory-state
  ``The state table behind the in-process backend, when that is the
  one this process made. What `bus/recent` reads; nil under any other
  backend, which is why `recent` says so rather than returning an
  empty tuple that would look like "nothing was published".``
  nil)

(defn recent
  ``The last messages the in-process backend saw, oldest first — an
  inspection buffer for a test and for `void bus tail`, never a replay
  log (see void/bus/memory).``
  [&opt n]
  (unless memory-state
    (error "bus/recent reads the in-process backend's history and this process is not using it — with a durable backend the log itself is the history (void bus tail)"))
  (map |(state/hydrate (state/active) $) (memory/recent memory-state n)))

# -- the broker component ------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :config-loaded
   :phase 100
   :name :bus/capture
   :doc "Remember the boot value — the resolved backends, codecs and middleware"
   :fn (fn capture [boot] (set state/current-boot boot))})

(defn- resolve-backend [cfg]
  (def factories (or (state/extension :void.bus/backend) @{}))
  (def name (cfg :backend))
  (def factory (backend/find-factory factories name))
  (backend/normalize ((factory :make) cfg)))

(defn- resolve-codec [cfg]
  (def cs (or (state/extension :void.bus/codec)
              # started outside a bootstrap (a REPL, a unit test): the
              # built-ins are what the point would have resolved to
              (tabseq [c :in codec/builtin] (c :name) (codec/normalize c))))
  (codec/find-codec cs (cfg :codec)))

(def broker-component
  (system/component :bus/broker
    :doc "The bus: the backend named by [:bus :backend], the codec
    named by [:bus :codec], and the middleware chain every delivered
    message runs through. Publishing needs nothing else; consuming
    starts at :after-start, once the components a handler is going to
    reach for are running."
    :provides [:void/bus]
    :config {:key :bus :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def b (resolve-backend cfg))
      (def c (resolve-codec cfg))
      (def contribs (or (state/extension :void.bus/middleware) []))
      (def tracer (state/resolve-tracer))
      (def br (state/make b c cfg contribs tracer))
      (set state/current-broker br)
      (def caps (backend/capabilities b))
      (log/info "bus ready" :ns log-ns
                :backend (caps :name) :codec (c :name)
                :delivery (caps :delivery) :durable (caps :durable)
                :shared (caps :shared) :ordering (caps :ordering)
                :group (br :group)
                :handlers (router/defined)
                :tracing (truthy? tracer))
      (unless (backend/durable? b)
        (log/warn "the bus backend does not survive a restart — a message published with nobody consuming is gone"
                  :ns log-ns :backend (caps :name)))
      br)
    :stop
    (fn stop [br]
      (state/stop-consumers! br)
      (protect ((get-in br [:backend :close])))
      (set state/current-broker nil)
      (set memory-state nil))
    :health
    (fn health [br]
      (def b (br :backend))
      (merge {:status :up
              :backend (b :name)
              :consumers (sorted (keys (br :consumers)))}
             (if-let [h (get b :health)] (h) {})))))

# -- starting and stopping the consumers ---------------------------------
#
# At :after-start rather than in the component's :start, for the reason
# void/obs installs its instrumentation there: a handler reaches for
# the database, the cache and whatever else the composition has, and
# the bus does not depend on any of them — so the only moment at which
# every one of them is certainly running is after the whole system is.

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 800
   :name :bus/consume
   :doc "Start a consumer per group the declared handlers ask for"
   :fn (fn start-consuming [boot]
         (when-let [br state/current-broker]
           (if (get-in br [:config :consume])
             (let [groups (state/start-consumers! br)]
               (when (empty? groups)
                 (log/debug "no bus handlers are declared in this process — publishing only"
                            :ns log-ns)))
             (log/info "bus consumers not started ([:bus :consume] is false)"
                       :ns log-ns :handlers (router/defined)))))})

(plugin/contribute! :void.core/hooks
  {:hook :before-stop
   :phase 200
   :name :bus/stop-consuming
   :doc "Stop the consumers before the components they reach for go away"
   :fn (fn stop-consuming [_]
         (when-let [br state/current-broker]
           (state/stop-consumers! br)))})

# -- the in-process backend ----------------------------------------------

(plugin/contribute! :void.bus/backend
  (memory/factory (fn remember-state [m] (set memory-state m))))

# -- CLI -----------------------------------------------------------------

(defn- with-broker [br f]
  (with-dyns [state/broker-dyn br] (f)))

(defn- flags
  "Parse --key VALUE pairs into a table, with `parse` deciding the
  value type per flag. Anything unknown is an error naming what is."
  [command args spec]
  (def out @{})
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (def key (get spec a))
    (unless key
      (errorf "%s: unknown flag %q (known: %s)"
              command a (string/join (sorted (keys spec)) " ")))
    (unless (< (inc i) (length args))
      (errorf "%s: %s needs a value" command a))
    (put out (key 0) ((key 1) (args (inc i))))
    (+= i 2))
  out)

(def- as-number |(or (scan-number $) (errorf "expected a number, got %q" $)))

(plugin/contribute! :void.core/cli
  {:name :bus/stats
   :doc "What this process's bus is and what it has carried: void bus stats"
   :needs [:bus/broker]
   :fn (fn cli-stats [br & args]
         (unless (empty? args)
           (errorf "void bus stats takes no arguments (got %q)" (string/join args " ")))
         (def s (with-broker br state/stats))
         (def caps (s :backend))
         (printf "backend     %q" (caps :name))
         (printf "delivery    %q" (caps :delivery))
         (printf "ordering    %q" (caps :ordering))
         (printf "durable     %s" (if (caps :durable) "yes" "no — a message nobody consumed is gone"))
         (printf "shared      %s" (if (caps :shared) "yes" "no — this process only"))
         (printf "codec       %q" (s :codec))
         (printf "group       %q" (s :group))
         (printf "outbox      %s" (if (s :outbox) "yes" "no (add :void/bus-db)"))
         (printf "tracing     %s" (if (s :tracing) "yes" "no (add :void/obs)"))
         (print)
         (printf "published   %d" (s :published))
         (printf "outboxed    %d" (s :outboxed))
         (printf "delivered   %d" (s :delivered))
         (unless (empty? (s :backend-stats))
           (print)
           (each k (sorted (map string (keys (s :backend-stats))))
             (printf "%-12s%q" k (get (s :backend-stats) (keyword k))))))})

(plugin/contribute! :void.core/cli
  {:name :bus/handlers
   :doc "Every declared handler, its topic and its group: void bus handlers"
   :fn (fn cli-handlers [& args]
         (unless (empty? args)
           (errorf "void bus handlers takes no arguments (got %q)" (string/join args " ")))
         (def names (router/defined))
         (if (empty? names)
           (print "no bus handlers are declared in this process")
           (do
             (printf "%-24s %-24s %-12s %s" "handler" "topic" "group" "doc")
             (each n names
               (def d (router/lookup n))
               (printf "%-24s %-24s %-12s %s"
                       (string n) (string (d :topic))
                       (string (get-in d [:opts :group] "-"))
                       (or (d :doc) ""))))))})

(plugin/contribute! :void.core/cli
  {:name :bus/publish
   :doc "Publish a message by hand: void bus publish TOPIC 'jdn payload'"
   :needs [:bus/broker]
   :fn (fn cli-publish [br & args]
         (unless (= 2 (length args))
           (error "usage: void bus publish TOPIC 'jdn payload'"))
         (def topic (keyword (first args)))
         (def payload (parse (args 1)))
         (def msg (with-broker br (fn [] (state/publish topic payload))))
         (printf "published %s on %q" (msg :id) topic))})

(plugin/contribute! :void.core/cli
  {:name :bus/tail
   :doc "The messages the in-process backend has seen: void bus tail [--limit N]"
   :needs [:bus/broker]
   :fn (fn cli-tail [br & args]
         (def o (flags "void bus tail" args {"--limit" [:limit as-number]}))
         (def rows (with-broker br (fn [] (recent (get o :limit 20)))))
         (if (empty? rows)
           (print "nothing has gone past")
           (each m rows (print (message/summary m)))))})

(plugin/contribute! :void.core/cli
  {:name :bus/consume
   :doc "Consume in the foreground, the way a worker process does: void bus consume"
   :needs [:bus/broker]
   :fn (fn cli-consume [br & args]
         (unless (empty? args)
           (errorf "void bus consume takes no arguments (got %q)" (string/join args " ")))
         (when (empty? (router/defined))
           (error "no bus handlers are declared in this process — `void bus consume` runs the handlers this process imported, and it imported none"))
         (def groups
           (if (empty? (br :consumers))
             (with-broker br (fn [] (state/start-consumers! br)))
             (sorted (keys (br :consumers)))))
         (printf "consuming %s — ^C to stop"
                 (string/join (map string groups) ", "))
         # the consumers are fibers of their own; this one only has to
         # stay alive, and it wakes rarely enough to cost nothing
         (forever (ev/sleep 3600)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/bus
  :doc "Messaging: plain-table messages on keyword topics, defhandler with a middleware chain on void/http's phase scale (retry, poison queue, dedup, correlation and a trace that continues out of the request), backends as an extension point with the delivery guarantee declared rather than assumed, and an in-process backend to start with."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :bus
  :config-schema Config
  :config-defaults defaults
  :components [broker-component])
