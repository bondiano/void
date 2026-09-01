### void/bus/backend — the `:void.bus/backend` contract (SPEC.md
### §5.22, ADR-0012).
###
### A backend is contributed as a **factory**, not as a component:
###
###     {:name :memory
###      :doc  "..."
###      :make (fn [cfg] backend)}
###
### and `[:bus :backend]` names the one this process uses — the shape
### `:void.mail/transport` has, and for the same reason. void/jobs
### does it the other way round (a component that `:provides
### [:void/jobs-backend]`) because a job store is a place an
### application may reasonably want two of, pointed at two databases.
### A bus backend is not that: it is the transport this deployment
### speaks, one per process, chosen by the operator in a config file —
### so it is a name, and a name that is wrong is a boot error listing
### the ones that exist.
###
### The backend a factory returns answers four questions and declares
### what it can promise:
###
###   :publish!    (fn [envelope])            hand a message over
###   :consume!    (fn [opts deliver] sub)    start a consumer
###   :stop!       (fn [sub])                 stop one
###   :close       (fn [])                    give up the resources
###
###   :guarantees  {:delivery :ordering :durable :shared} — see below
###   :encoded?    does it store bytes (then a codec must produce
###                some) or values in this process's heap
###   :stats       (fn [] {...})              what `void bus stats`
###                prints
###
### An **envelope** is a message with its payload and meta already
### through the codec: `{:id :topic :body :meta-body :meta}`. Both the
### encoded halves and the live meta table are on it, because a
### backend with columns writes the encoded ones and a backend in the
### heap keeps the live one, and neither should have to re-encode to
### find a correlation id.
###
### `consume!` opts: `{:group :topics :batch}`. A **group** is the unit
### of fan-out — every group sees every message it subscribes to, and
### within a group a message is delivered once. Two processes of the
### same service share a group and split the log; two different
### services use two groups and both see everything. `:topics` is the
### tuple of patterns the router has handlers for, a *hint*: a backend
### may use it to filter (void/bus-db turns a fully exact list into
### `topic IN (...)`) and a backend that ignores it is still correct,
### because the router matches again on arrival.
###
### `deliver` is `(fn [message] ...)`. Returning is an ack. **Throwing
### is a nack**, and what a nack means is the backend's declared
### guarantee and nothing else: an `:at-least-once` backend redelivers
### the message, an `:at-most-once` backend drops it. This is the one
### place in void where "what happens when it fails" is not the
### runtime's decision, because it cannot be — the runtime cannot
### redeliver what a process never stored.
###
### `guarantees`:
###
###   :delivery  :at-most-once | :at-least-once
###   :ordering  :none | :per-group (messages reach one group in
###              publish order)
###   :durable   does a message survive this process dying
###   :shared    do several processes see the same log
###
### They are declared, not derived, and the router reads them: the
### retry middleware is on by default under `:at-most-once` (nobody
### else will re-run the handler) and off by default under
### `:at-least-once` (the backend will), and `bus/publish-tx!` refuses
### a backend that is not `:durable`, because an outbox in front of a
### queue that forgets is a longer way to lose the message.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def- required [:publish! :consume! :stop!])
(def- optional [:close :stats :health])

(def deliveries
  "Every delivery guarantee a backend may declare."
  [:at-most-once :at-least-once])

(def orderings
  "Every ordering guarantee a backend may declare."
  [:none :per-group])

(def default-guarantees
  ``What a backend promises when it says nothing: the weakest of
  everything. A backend that forgets to declare is not thereby
  trusted — it is trusted less, and the router turns its own retries
  on to compensate.``
  {:delivery :at-most-once
   :ordering :none
   :durable false
   :shared false})

(defn- check-guarantees [name g0]
  (def g (merge @{} default-guarantees (or g0 {})))
  (unless (index-of (g :delivery) deliveries)
    (errorf "bus backend %q: :delivery must be one of %s, got %q"
            name (string/join (map string deliveries) " ") (g :delivery)))
  (unless (index-of (g :ordering) orderings)
    (errorf "bus backend %q: :ordering must be one of %s, got %q"
            name (string/join (map string orderings) " ") (g :ordering)))
  (each k [:durable :shared]
    (unless (boolean? (g k))
      (errorf "bus backend %q: %q must be a boolean, got %q" name k (g k))))
  (table/to-struct g))

(defn normalize
  ``Validate a backend dictionary and fill in the documented
  fallbacks, so the router can call every key unconditionally — the
  shape void/db/driver and void/jobs/backend have, for the same
  reason.``
  [b]
  (unless (dictionary? b)
    (errorf "bus backend must be a dictionary, got %q" b))
  (def name (get b :name :anonymous))
  (each k required
    (unless (callable? (get b k))
      (errorf "bus backend %q: %q must be a function, got %q" name k (get b k))))
  (each k optional
    (when-let [f (get b k)]
      (unless (callable? f)
        (errorf "bus backend %q: %q must be a function, got %q" name k f))))
  (table/to-struct
    (merge
      @{:name name
        :encoded? true
        :stats (fn no-stats [] {})
        :health nil
        :close (fn no-close [] nil)}
      b
      @{:guarantees (check-guarantees name (get b :guarantees))})))

(defn normalize-factory
  "Validate a `:void.bus/backend` contribution — the factory, not the
  backend it makes."
  [c]
  (unless (dictionary? c)
    (errorf "bus backend contribution must be a dictionary, got %q" c))
  (def name (get c :name))
  (unless (keyword? name)
    (errorf "bus backend contribution: :name must be a keyword, got %q" name))
  (unless (callable? (get c :make))
    (errorf "bus backend %q: :make must be a function, got %q" name (get c :make)))
  (table/to-struct (merge @{:doc nil} c)))

(defn find-factory
  "The backend factory named by `name`, or an error listing what this
  composition actually has."
  [factories name]
  (or (get factories name)
      (errorf "unknown bus backend %q (contributed: %s) — [:bus :backend] names the one this process speaks"
              name
              (string/join (map |(string/format "%q" $) (sorted (keys factories))) " "))))

(defn at-least-once?
  "Does the backend redeliver a message whose handler threw?"
  [b]
  (= :at-least-once (get-in b [:guarantees :delivery])))

(defn durable?
  "Does a published message survive this process dying?"
  [b]
  (truthy? (get-in b [:guarantees :durable])))

(defn shared?
  "Do several processes see the same messages?"
  [b]
  (truthy? (get-in b [:guarantees :shared])))

(defn capabilities
  ``What this backend actually promises, as data — what `void bus
  stats` prints and what the broker logs at boot, so that "these
  messages do not survive a restart" is something an operator reads
  rather than discovers.``
  [b]
  (merge {:name (b :name) :encoded (truthy? (b :encoded?))}
         (b :guarantees)))

(defn require-durable!
  "Throw unless the backend keeps a published message across a
  restart — what the transactional outbox demands of whatever it
  forwards into."
  [b who]
  (unless (durable? b)
    (errorf "%s needs a durable bus backend and %q is not one: a message published through an outbox and then forgotten by the transport is the outcome the outbox exists to prevent. Compose void/bus-db and set [:bus :backend] to :db"
            who (b :name)))
  true)
