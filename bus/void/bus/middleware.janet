### void/bus/middleware — the chain a message passes through on its
### way to a handler (SPEC.md §5.22, ROADMAP 3.6).
###
### A middleware is a wrapper `(fn [handler opts] handler')` over
### `(fn [message] result)`, registered through `:void.bus/middleware`
### with a numeric phase — the same shape and the same scale
### `void/http` uses, so that "lower runs earlier, outermost" is one
### fact to learn rather than two. The one difference is the second
### argument: `:wrap` is handed the *handler's own options* — its
### topic, its group, its schema — because a bus handler's options are
### fixed at declaration and the chain is built per handler, so a
### middleware that depends on them can close over them once instead
### of looking them up per message. void/http's wrapper cannot: a
### route's metadata is not known until the request names the route,
### which is why it reads it off `(req :void/route)` instead. **The constants are HTTP's where
### the meaning is the same**: `:panic-guard` still means "nothing
### below me may kill the fiber", `:observability` still means "the
### log context and the span are bound from here down",
### `:validation`, `:business` and `:response` still mean what they
### mean. The slots HTTP spends on sessions, authentication and
### authorization are the ones a message has no use for — a message
### carries its authority in its meta or does not have any — so bus
### spends them on the three concerns a delivery has and a request
### does not:
###
###   0     :panic-guard    a handler that throws must reach the
###                         backend as a nack and nothing else
###   1000  :observability  correlation, causation, the continued trace
###   2000  :poison         a message that cannot be handled leaves the
###                         rotation instead of blocking it
###   3000  :retry          try again here, before the backend is told
###   4000  :dedup          the same message twice is one delivery
###   5000  :throttle       a consumer's own pace
###   6000  :validation     the payload is what the handler declared
###   7000  :business       user middleware, by default
###   9000  :response       whatever comes after the handler returned
###
### **Retry and redelivery are the same concern at two distances**, and
### running both by default would multiply. So the retry middleware
### reads the backend's declared guarantee: under `:at-most-once`
### nobody else will re-run the handler and retrying here is the only
### retry there is, so it is on; under `:at-least-once` the backend
### will hand the message over again, and retrying here as well turns
### three attempts into nine. `[:bus :retry :enabled]` overrides the
### default in either direction, and the broker logs which way it went.
###
### **Poison is the outer half of the same decision.** A message that
### has been redelivered more times than `[:bus :poison :max-attempts]`
### is published to the poison topic and *acked*: the alternative is a
### message that fails forever at the head of an ordered group, which
### is not a lost message but a stopped consumer, and the second is
### worse than the first.
###
### **Dedup is in this process's heap** unless something else is given,
### the way void/jobs's rate limiter is, and `void bus stats` says so:
### deduplicating per process is exactly right for the duplicates a
### single consumer's own redelivery makes and no help at all against
### two consumers in two processes. The honest use is the one the
### outbox creates — a forwarder that published and died before
### marking the row — and that duplicate arrives at the same group.

(import void/core/log :as log)
(import void/core/schema :as schema)
(import ./message :as message)

(def log-ns "void.bus")

(def phases
  "The standard phase constants (see the module docstring)."
  {:panic-guard 0
   :observability 1000
   :poison 2000
   :retry 3000
   :dedup 4000
   :throttle 5000
   :validation 6000
   :business 7000
   :response 9000})

(def phase/panic-guard (phases :panic-guard))
(def phase/observability (phases :observability))
(def phase/poison (phases :poison))
(def phase/retry (phases :retry))
(def phase/dedup (phases :dedup))
(def phase/throttle (phases :throttle))
(def phase/validation (phases :validation))
(def phase/business (phases :business))
(def phase/response (phases :response))

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn normalize
  "Validate a `:void.bus/middleware` contribution and fill in its
  defaults."
  [c]
  (unless (dictionary? c)
    (errorf "bus middleware must be a dictionary, got %q" c))
  (def name (get c :name))
  (unless (keyword? name)
    (errorf "bus middleware: :name must be a keyword, got %q" name))
  (unless (callable? (get c :wrap))
    (errorf "bus middleware %q: :wrap must be a function, got %q" name (get c :wrap)))
  (def phase (get c :phase phase/business))
  (unless (number? phase)
    (errorf "bus middleware %q: :phase must be a number, got %q" name phase))
  (when-let [pred (get c :when)]
    (unless (callable? pred)
      (errorf "bus middleware %q: :when must be a function, got %q" name pred)))
  (table/to-struct (merge @{:doc nil :named false :when nil} c {:phase phase})))

(defn sort-contributions
  "Deterministic chain order: ascending phase, ties broken by the
  contributing plugin's name, then the middleware name."
  [contribs]
  (sorted-by
    (fn [c] [(get c :phase phase/business)
             (string (get c :plugin ""))
             (string (get c :name ""))])
    contribs))

(defn select
  ``The middleware that apply to one handler: the global ones whose
  `:when` predicate accepts the handler's options, plus the `:named`
  ones the handler lists under `:middleware`. An unknown name is an
  error — the chain is built once, at start, so a typo is a boot
  failure and never a message that quietly skipped its validation.``
  [contribs opts]
  (def by-name (tabseq [c :in contribs] (c :name) c))
  (def wanted (tabseq [n :in (get opts :middleware [])] n true))
  (each n (sorted (keys wanted))
    (unless (in by-name n)
      (errorf "bus handler %q selects unknown middleware %q (known: %s)"
              (get opts :name)
              n (string/join (map |(string/format "%q" $) (sorted (keys by-name))) " "))))
  (seq [c :in (sort-contributions contribs)
        :when (if (c :named) (in wanted (c :name)) true)
        :when (if-let [pred (c :when)] (pred opts) true)]
    c))

(defn chain
  ``Compose selected middleware around a handler: the lowest phase
  ends up outermost. `opts` is the handler's own options, handed to
  every `:wrap` (see the module docstring).``
  [selected handler &opt opts]
  (default opts {})
  (var h handler)
  (loop [i :down-to [(dec (length selected)) 0]]
    (set h (((selected i) :wrap) h opts)))
  h)

# -- the built-ins -------------------------------------------------------

(defn panic-guard
  ``Log a failed delivery with everything needed to find it again —
  the handler, the topic, the message id, the correlation id — and
  re-raise, because what a failure *means* is the backend's declared
  guarantee and this middleware has no business deciding it.``
  []
  {:name :bus/panic-guard
   :phase phase/panic-guard
   :doc "Log a failed delivery and re-raise it as a nack"
   :wrap
   (fn wrap-guard [handler _]
     (fn guarded [msg]
       (try (handler msg)
         ([err fib]
           (log/error "bus handler failed" :ns log-ns
                      :topic (msg :topic) :id (msg :id)
                      :correlation-id (message/correlation-id msg)
                      :redelivery (message/redelivery msg)
                      :err (if (string? err) err (describe err)))
           (propagate err fib)))))})

(defn correlation
  ``Bind the message's correlation and causation onto the fiber and
  into the log context, so that everything the handler does — every
  log line, every message it publishes in turn — carries the same
  thread back to the request that started it.

  This is the whole of "context propagation" for the ninety per cent
  of it that is not a trace: it needs no exporter, no collector and no
  `void/obs` in the composition.``
  []
  {:name :bus/correlation
   :phase phase/observability
   :doc "Bind the correlation and causation ids for the handler's extent"
   :wrap
   (fn wrap-correlation [handler _]
     (fn correlated [msg]
       (with-dyns [message/correlation-dyn (message/correlation-id msg)
                   message/causation-dyn (msg :id)]
         (log/with-context {:correlation-id (message/correlation-id msg)
                            :message-id (msg :id)
                            :topic (msg :topic)}
           (handler msg)))))})

(defn tracing
  ``Continue the publisher's trace in the consumer: the `:traceparent`
  the message carries becomes the remote parent of a span around the
  handler, so a request that published and a worker that consumed are
  one trace with a gap in the middle rather than two traces nobody can
  join.

  `start-span`/`end-span!` are handed in by the broker, which resolved
  them out of `void/obs` **the public way** — with `require`, at
  start, and nil when that package is not on this process's module
  path (the seam void/obs itself uses to instrument void/db without
  depending on it). void/bus has no edge to void/obs and contributes
  to none of its points: a contribution to a point no active plugin
  owns is a boot error, so a bus that reached for obs by manifest
  would break every application that runs a bus without one.``
  [tracer]
  {:name :bus/tracing
   :phase (+ phase/observability 1)
   :doc "A consumer span under the publisher's trace"
   :wrap
   (fn wrap-tracing [handler _]
     (fn traced [msg]
       (def remote ((tracer :parse) (get-in msg [:meta :traceparent])))
       ((tracer :with-span)
         (string "bus consume " (msg :topic))
         {:kind :consumer
          :remote remote
          :attrs @{:messaging.system "void.bus"
                   :messaging.destination (string (msg :topic))
                   :messaging.message_id (msg :id)
                   :messaging.operation "process"}}
         (fn traced-body [] (handler msg)))))})

(defn- backoff-delay [cfg attempt]
  (def base (get cfg :base 0.2))
  (def cap (get cfg :max 30))
  (def jitter (get cfg :jitter 0.25))
  (def raw
    (case (get cfg :strategy :exponential)
      :fixed base
      :linear (* base attempt)
      (* base (math/exp2 (dec attempt)))))
  (def capped (min cap raw))
  (+ capped (* capped jitter (math/random))))

(defn retry
  ``Try the rest of the chain again, `:attempts` times, with backoff
  and jitter. On the last failure the error is re-raised, which is
  what puts the message in front of the poison middleware and, under
  an at-least-once backend, back in the log.

  `cfg`: `{:attempts 3 :strategy :exponential :base 0.2 :max 30
  :jitter 0.25}`.``
  [cfg]
  {:name :bus/retry
   :phase phase/retry
   :doc "Retry a failed handler with backoff and jitter"
   :wrap
   (fn wrap-retry [handler _]
     (def attempts (max 1 (get cfg :attempts 3)))
     (fn retried [msg]
       (var n 0)
       (var out nil)
       (var done false)
       (while (not done)
         (++ n)
         (def [ok res] (protect (handler msg)))
         (cond
           ok (do (set out res) (set done true))
           (>= n attempts) (error res)
           (do
             (def wait (backoff-delay cfg n))
             (log/warn "bus handler failed, retrying" :ns log-ns
                       :topic (msg :topic) :id (msg :id)
                       :attempt n :of attempts :in wait
                       :err (if (string? res) res (describe res)))
             (ev/sleep wait))))
       out))})

(defn poison
  ``Take a message that has been redelivered too often out of the
  rotation: publish it on the poison topic and ack it. `publish` is
  the broker's own, so a poisoned message is an ordinary message —
  visible in `void bus tail`, consumable by a handler that files a
  ticket, and durable wherever the backend is.

  The counter is `:redelivery`, which the router puts on the message
  from what the backend says, not an attempt count kept in this
  process: the whole reason a message is poison is usually that the
  process which last tried it is gone.``
  [cfg publish]
  {:name :bus/poison
   :phase phase/poison
   :doc "Publish a repeatedly failing message to the poison topic and stop redelivering it"
   :wrap
   (fn wrap-poison [handler _]
     (def limit (get cfg :max-attempts 5))
     (def topic (get cfg :topic :bus/poison))
     (fn poison-guard [msg]
       (def [ok res] (protect (handler msg)))
       (cond
         ok res
         (< (message/redelivery msg) (dec limit)) (error res)
         (do
           (log/error "message poisoned" :ns log-ns
                      :topic (msg :topic) :id (msg :id)
                      :correlation-id (message/correlation-id msg)
                      :redelivery (message/redelivery msg)
                      :err (if (string? res) res (describe res)))
           (publish topic
                    {:message-id (msg :id)
                     :topic (string (msg :topic))
                     :payload (msg :payload)
                     :redelivery (message/redelivery msg)
                     :error (if (string? res) res (describe res))}
                    {:correlation-id (message/correlation-id msg)})
           # acked: the message leaves the rotation. An ordered group
           # whose head fails forever is a stopped consumer, and that
           # is worse than the one message this gives up on
           nil))))})

(defn validate
  ``Check a message's payload against the schema its handler declared
  (`{:topic :order/paid :schema OrderPaid}`) before the handler sees
  it. A payload that does not match is an error like any other — it
  nacks, it counts towards poison, and it lands on the poison topic
  with the validation failure in its `:error`, which is where a
  message from a publisher that changed its mind about the shape
  belongs.

  **Coercion is on.** The codec that carried the message here is
  usually JSON, so a field that went out an integer and came back one
  is luck rather than a rule; a schema that says `:int` is a statement
  about the domain, not about the encoding, and the coerced value is
  what the handler receives. That is also how a keyword field survives
  the round trip a JSON codec cannot make on its own (./codec).

  Only handlers that declared a schema get this in their chain: a
  frame per message that checks nothing is still a frame per message.``
  []
  {:name :bus/validate
   :phase phase/validation
   :doc "Validate (and coerce) a payload against the handler's :schema"
   :when (fn wants-validation? [opts] (truthy? (get opts :schema)))
   :wrap
   (fn wrap-validate [handler opts]
     (def sch (get opts :schema))
     (fn validated [msg]
       (def [ok res] (protect (schema/validate sch (msg :payload) {:coerce true})))
       (unless ok
         (errorf "message %s on %q does not match the schema %q declares: %s"
                 (msg :id) (msg :topic) (get opts :name :handler)
                 (if (string? res) res (describe res))))
       (handler (merge @{} msg {:payload res}))))})

(defn dedup
  ``Deliver a message id once per window. The seen-set is a table in
  this process's heap with a coarse two-generation expiry: ids move
  into a cold half when the window turns and are dropped when it turns
  again, so the memory is bounded by the arrival rate and the check
  stays two lookups.

  Per process, and `void bus stats` says so — see the module
  docstring for the duplicate this is actually for.``
  [cfg]
  {:name :bus/dedup
   :phase phase/dedup
   :doc "Skip a message id already delivered inside the dedup window"
   :wrap
   (fn wrap-dedup [handler _]
     (def window (get cfg :window 300))
     (var hot @{})
     (var cold @{})
     (var turned (os/clock :monotonic))
     (def stats @{:skipped 0})
     (fn deduped [msg]
       (def now (os/clock :monotonic))
       (when (> (- now turned) window)
         (set cold hot)
         (set hot @{})
         (set turned now))
       (def id (msg :id))
       (if (or (in hot id) (in cold id))
         (do
           (put stats :skipped (inc (stats :skipped)))
           (log/debug "duplicate message skipped" :ns log-ns
                      :topic (msg :topic) :id id)
           nil)
         (do
           (put hot id true)
           (handler msg)))))})

(defn throttle
  ``Hold a consumer to `:max` messages per `:window` seconds, by
  sleeping before the handler rather than by dropping: a bus consumer
  that is being paced has somewhere to wait — the log it is reading
  from — which is exactly what an HTTP request does not have, and why
  this is a throttle and `void/security`'s is a limiter.``
  [cfg]
  {:name :bus/throttle
   :phase phase/throttle
   :doc "Pace a consumer to a maximum rate, by waiting"
   :wrap
   (fn wrap-throttle [handler _]
     (def limit (get cfg :max 0))
     (def window (get cfg :window 1))
     (var start 0)
     (var n 0)
     (fn throttled [msg]
       (when (pos? limit)
         (var admitted false)
         (while (not admitted)
           (def now (os/clock :monotonic))
           (def w (* window (math/floor (/ now window))))
           (when (not= w start) (set start w) (set n 0))
           (if (< n limit)
             (do (++ n) (set admitted true))
             (ev/sleep (max 0.001 (- (+ w window) now))))))
       (handler msg)))})
