### void/bus/message — a message, and what a topic is (SPEC.md §5.22,
### ADR-0012).
###
### A message is a plain table:
###
###     {:id "018f...c4" :topic :user/created
###      :payload {:id 42 :email "a@example.com"}
###      :meta {:published-at 1756... :correlation-id "..." ...}}
###
### Four keys and no builder (ADR-0004), for the reason void/mail has
### no builder either: a message that is a table can be written by
### hand in a test, compared field by field in an assertion, printed
### whole in a log line and stored as four columns by a backend that
### has columns. `make` is a normalizer, not a constructor — it fills
### in what was not said and refuses what cannot be meant.
###
### **The payload is the application's, the meta is the framework's.**
### Everything void puts on a message — when it was published, which
### correlation it belongs to, which trace it continues, how many times
### it has been delivered — goes in `:meta`, and nothing void writes
### ever lands in `:payload`. A consumer reading `(msg :payload)` sees
### exactly what the publisher passed and nothing else, which is what
### makes a payload schema (./cqrs) a statement about the domain
### rather than about the transport.
###
### **A topic is a keyword**, and a subscription may name one of three
### things: an exact topic (`:user/created`), every topic in a
### namespace (`:user/*`) or every topic at all (`:*`). Three forms,
### because the fourth — a glob, a regex, a hierarchy of arbitrary
### depth — buys a routing language that has to be learnt, debugged
### and made fast, and Janet's own two-part keyword already says
### "which subsystem, which event". A pattern that matches nothing at
### boot is not an error: the publisher of `:user/created` may be a
### service that is not deployed yet, and a consumer that refused to
### start until it existed would be a deployment order dressed up as a
### validation.

(def fields
  ``Every field of a message, in a stable order — the order `void bus
  show` prints and the column order void/bus-db creates.``
  [:id :topic :payload :meta])

(def meta-keys
  ``The `:meta` keys void itself writes. An application may put
  anything else there; these are the ones the framework reads back,
  and they are documented because a consumer in another language has
  to be able to find them.

    :published-at    realtime clock at publish
    :correlation-id  the unit of work this message belongs to — the
                     request that caused it, and every message caused
                     by those messages in turn
    :causation-id    the id of the message that directly caused this
                     one (nil for a message caused by a request)
    :traceparent     W3C trace context, so a consumer's span hangs
                     under the request's (./middleware)
    :reply-to        a topic a reply is expected on (./cqrs)
    :redelivery      how many times a backend has handed this message
                     over before — set by the router, not the
                     publisher``
  [:published-at :correlation-id :causation-id :traceparent :reply-to
   :redelivery])

(def correlation-dyn
  ``Dynamic binding: the correlation id every message published on
  this fiber inherits. void/http's request id goes in here at the edge
  and the whole causal fan-out of a request carries it, which is the
  entire point — a log search on one id finds the request, the
  messages it published, and the messages those published.``
  :void.bus/correlation-id)

(def causation-dyn
  "Dynamic binding: the id of the message being handled, which becomes
  the `:causation-id` of everything published while handling it. The
  router binds it; nothing else should."
  :void.bus/causation-id)

# -- ids -----------------------------------------------------------------

(defn- hex [bytes]
  (string/join (seq [b :in bytes] (string/format "%02x" b))))

(defn new-id
  ``A message id: the second it was published, then eight random
  bytes. Sortable by time to the second, unique below it, and the same
  shape a job id has (void/jobs/record) — an id that sorts is what
  lets a message log be read in order by a human with a SQL client and
  by a cursor that has to resume.``
  [&opt now]
  (string/format "%011x%s" (math/floor (or now (os/time))) (hex (os/cryptorand 8))))

# -- topics --------------------------------------------------------------

(defn topic?
  "Is `x` a usable topic — a keyword that is not a pattern?"
  [x]
  (and (keyword? x)
       (not= x :*)
       (not (string/has-suffix? "/*" (string x)))))

(defn pattern?
  "Is `x` a usable subscription pattern — an exact topic, `:ns/*` or
  `:*`?"
  [x]
  (and (keyword? x)
       (or (= x :*)
           (string/has-suffix? "/*" (string x))
           (topic? x))))

(defn exact?
  "Is this pattern a single topic, rather than a wildcard? What lets a
  backend turn a subscription into a `topic IN (...)` filter."
  [pattern]
  (topic? pattern))

(defn matches?
  ``Does `topic` match subscription `pattern`? `:*` matches
  everything, `:ns/*` matches every topic in that namespace, anything
  else matches itself.``
  [pattern topic]
  (cond
    (= pattern :*) true
    (= pattern topic) true
    (let [p (string pattern)]
      (and (string/has-suffix? "/*" p)
           (string/has-prefix? (string/slice p 0 (- (length p) 1)) (string topic))))))

(defn check-pattern!
  "Throw unless `pattern` is one of the three subscription forms."
  [pattern &opt who]
  (unless (pattern? pattern)
    (errorf "%s: %q is not a topic pattern — a topic is a keyword (:user/created), a namespace is :user/*, and everything is :*"
            (or who "bus") pattern))
  pattern)

# -- the message ---------------------------------------------------------

(defn- meta-table [m]
  (cond
    (nil? m) @{}
    (dictionary? m) (merge @{} m)
    (errorf "bus: a message :meta must be a dictionary, got %q" m)))

(defn make
  ``Normalize a message. Everything but the topic is optional:

      (message/make :user/created {:id 42})
      (message/make :user/created payload
        {:id "..." :meta {:tenant "acme"} :reply-to :user/created-ack})

  Options: `:id`, `:meta` (merged under the framework's keys —
  an application's own meta survives), `:correlation-id`,
  `:causation-id`, `:reply-to`, `:at` (the publish clock, for a test
  that wants a fixed one).

  The correlation id, when nothing names one, is inherited from the
  fiber (`correlation-dyn`) and falls back to the message's own id:
  the first message of a chain correlates the chain.``
  [topic payload &opt opts]
  (default opts {})
  (unless (topic? topic)
    (errorf "bus: a topic must be a keyword like :user/created, got %q — :* and :ns/* are subscription patterns, not topics"
            topic))
  (def id (or (opts :id) (new-id (opts :at))))
  (def meta (meta-table (opts :meta)))
  (put meta :published-at (or (get meta :published-at) (opts :at) (os/clock :realtime)))
  (put meta :correlation-id
       (or (opts :correlation-id) (get meta :correlation-id) (dyn correlation-dyn) id))
  (when-let [cause (or (opts :causation-id) (get meta :causation-id) (dyn causation-dyn))]
    (put meta :causation-id cause))
  (when-let [reply (or (opts :reply-to) (get meta :reply-to))]
    (put meta :reply-to reply))
  @{:id id :topic topic :payload payload :meta meta})

(defn message?
  "Is `x` shaped like a message — an id, a topic and a meta table?"
  [x]
  (and (dictionary? x)
       (string? (get x :id))
       (keyword? (get x :topic))
       (dictionary? (get x :meta))))

(defn correlation-id
  "The correlation id of a message."
  [msg]
  (get-in msg [:meta :correlation-id]))

(defn redelivery
  "How many times this message has been handed over before — 0 on a
  first delivery."
  [msg]
  (get-in msg [:meta :redelivery] 0))

(defn with-meta
  "A copy of `msg` with `kvs` merged into its meta. The message itself
  is not mutated: a middleware that annotates a message must not
  change the one a retry will replay."
  [msg kvs]
  (merge @{} msg {:meta (merge @{} (get msg :meta {}) kvs)}))

(defn summary
  "One line for a listing — what `void bus tail` prints."
  [msg]
  (string/format "%s  %-24s corr=%s%s  %j"
                 (get msg :id "-")
                 (string (get msg :topic :?))
                 (or (correlation-id msg) "-")
                 (let [r (redelivery msg)] (if (pos? r) (string/format " redelivery=%d" r) ""))
                 (get msg :payload)))
