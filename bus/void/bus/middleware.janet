### void/bus/middleware — the chain a message passes through on its way to
### a handler.
###
### A middleware is a wrapper `(fn [handler opts] handler')` over
### `(fn [message] result)`, registered through `:void.bus/middleware`.
### It says where it runs the way `void/http`'s middleware does — with
### edges, `:after` and `:before` a named anchor of the chain
### (`anchors`) or a named neighbour — and one sort (void/core/order)
### turns the edges into the chain order, once per broker. The one
### difference is the second argument: `:wrap` is handed the
### *handler's own options* — its topic, its group, its schema —
### because a bus handler's options are fixed at declaration and the
### chain is built per handler, so a middleware that depends on them
### can close over them once instead of looking them up per message.
### void/http's wrapper cannot: a route's metadata is not known until
### the request names the route.
###
### The anchors, outermost first, and the built-ins between them:
###
###   :bus/panic-guard        a handler that throws must reach the
###                           backend as a nack and nothing else
###   :void.bus/guarded       — nothing below may kill the fiber
###   :bus/correlation        correlation and causation, bound
###   :bus/tracing            the publisher's trace, continued (with
###                           void/obs on the module path)
###   :void.bus/observed      — the log context and the span are bound
###   :bus/poison             a message that cannot be handled leaves
###                           the rotation instead of blocking it
###   :bus/retry              try again here, before the backend is told
###   :bus/dedup              the same message twice is one delivery
###   :bus/throttle           a consumer's own pace
###   :void.bus/admitted      — the message is being delivered, once
###   :bus/validate           the payload is what the handler declared
###   :void.bus/validated     — the payload is the declared shape
###
### A built-in the [:bus] slice turns off is simply not in the chain,
### and its neighbours close up around it. User middleware usually
### goes `:after :void.bus/validated`; one that wants to see a message
### before it is counted or paced goes `:before :void.bus/admitted`.
### A contribution tied to no anchor, an edge to a name nothing has, a
### neighbour of a plugin the contributor does not require and a cycle
### all fail the boot; a leftover `:phase` is an error (ADR-0051).
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

(import void/core/errors :as errors)
(import void/core/log :as log)
(import void/core/order :as order)
(import void/core/schema :as schema)
(import ./message :as message)
(import void/core/util :as util)

(def log-ns "void.bus")

# -- anchors and the spine -----------------------------------------------

(def anchors
  "The :void.bus/middleware anchors, outermost first."
  [:void.bus/guarded :void.bus/observed :void.bus/admitted :void.bus/validated])

(def spine
  ``The built-ins and the anchors between them, outermost first: a
  built-in's edges are its neighbours here once the absent ones are
  passed over.``
  [:bus/panic-guard :void.bus/guarded
   :bus/correlation :bus/tracing :void.bus/observed
   :bus/poison :bus/retry :bus/dedup :bus/throttle :void.bus/admitted
   :bus/validate :void.bus/validated])

(defn- spine-edges
  {:params [[:keyword]] :ret @{:keyword {:after :keyword? :before :keyword?}}}
  ``Each of `present` built-in names -> its `:after`/`:before`: the
  neighbours it has in `spine` once every built-in not in `present`
  is dropped.``
  [present]
  (def here (tabseq [n :in present] n true))
  (def line (filter |(or (index-of $ anchors) (in here $)) spine))
  (tabseq [[i n] :pairs line :when (in here n)]
    n {:after (get line (dec i)) :before (get line (inc i))}))

(def- phase-removed
  "What a leftover :phase is told."
  "has :phase, which was removed in ADR-0051: place it with :after/:before an anchor (middleware/anchors) or a neighbour")

(defn normalize
  {:params [:any]
   :ret BusMiddleware
   :throws [:string]}
  ``Validate a `:void.bus/middleware` contribution and fill in its
  defaults. It must say where it runs — `:after` or `:before` an
  anchor or a neighbour; a leftover `:phase` is an error.``
  [c]
  (unless (dictionary? c)
    (errorf "bus middleware must be a dictionary, got %q" c))
  (def name (get c :name))
  (unless (keyword? name)
    (errorf "bus middleware: :name must be a keyword, got %q" name))
  (unless (util/callable? (get c :wrap))
    (errorf "bus middleware %q: :wrap must be a function, got %q" name (get c :wrap)))
  (unless (nil? (get c :phase))
    (errorf "bus middleware %q %s" name phase-removed))
  (def placed
    (seq [side :in [:after :before]
          :let [[ok es] (protect (order/edges (get c side)))]]
      (unless ok
        (errorf "bus middleware %q: %s %s" name side es))
      es))
  (when (all empty? placed)
    (errorf "bus middleware %q is not placed: give it :after or :before one of the anchors %s"
            name (string/join (map |(string/format "%q" $) anchors) " ")))
  (when-let [pred (get c :when)]
    (unless (util/callable? pred)
      (errorf "bus middleware %q: :when must be a function, got %q" name pred)))
  (table/to-struct (merge @{:doc nil :named false :when nil} c)))

(defn place-built-ins
  {:params [[{:name :keyword :wrap (fn [:any :any] :any) & r}]]
   :ret @[BusMiddleware]
   :throws [:string]}
  ``The built-ins a broker runs, each given its `:after`/`:before`
  from its neighbours in `spine` among the ones present, and
  normalized.``
  [built-ins]
  (def edges (spine-edges (map |($ :name) built-ins)))
  (map |(normalize (merge $ (in edges ($ :name)))) built-ins))

(defn order
  {:params [[BusMiddleware] (or :nil {:requires (or {:keyword :any} :nil)})]
   :ret @[BusMiddleware]
   :throws [:string]}
  ``Normalized middleware — the placed built-ins and the contributions,
  each carrying the `:plugin` it came from — in the order their edges
  give, outermost first; the anchors are not in it. Once per broker.
  `:requires` (plugin -> its manifest's `:requires`) confines a
  contribution's neighbours to its own plugin, void/bus and the
  plugins it requires; nil skips that check. Every error at once; a
  cycle prints its path.``
  [middleware &opt opts]
  (filter |(nil? ($ :anchor))
          (order/sort middleware
                      {:anchors anchors
                       :what "bus middleware"
                       :owner :void/bus
                       :requires (get opts :requires)})))

(defn placement-check
  {:params [[{:name :keyword & r}]] :ret :nil :throws [:string]}
  ``The point's :validate: every contribution normalizes (placed, no
  `:phase`) and orders against the anchors and every built-in, so a
  bad edge or a cycle fails the boot — dry-run included — rather than
  the broker's start. Whether a neighbour belongs to a required plugin
  is the broker's to check: a contribution value does not know its
  plugin.``
  [values]
  (def built-ins
    (map (fn [[n e]] (merge {:name n} e))
         (pairs (spine-edges (filter |(not (index-of $ anchors)) spine)))))
  (order/sort [;built-ins ;(map normalize values)]
              {:anchors anchors :what "bus middleware"})
  nil)

(defn select
  {:params [[BusMiddleware] {:name :any :middleware (or :nil [:keyword]) & r}]
   :ret @[BusMiddleware]
   :throws [:string]}
  ``The middleware that apply to one handler, out of `ordered` (what
  `order` answers), in that order: the global ones whose `:when`
  predicate accepts the handler's options, plus the `:named` ones the
  handler lists under `:middleware`. An unknown name is an error — the
  chain is built once, at start, so a typo is a boot failure and never
  a message that quietly skipped its validation.``
  [ordered opts]
  (def by-name (tabseq [c :in ordered] (c :name) c))
  (def wanted (tabseq [n :in (get opts :middleware [])] n true))
  (each n (sorted (keys wanted))
    (unless (in by-name n)
      (errorf "bus handler %q selects unknown middleware %q (known: %s)"
              (get opts :name)
              n (util/names-str (keys by-name)))))
  (seq [c :in ordered
        :when (if (c :named) (in wanted (c :name)) true)
        :when (if-let [pred (c :when)] (pred opts) true)]
    c))

(defn chain
  {:params [[BusMiddleware] (fn [:any] :any) (or :nil {:keyword :any})]
   :ret (fn [:any] :any)}
  ``Compose selected middleware around a handler, the first one
  outermost. `opts` is the handler's own options, handed to every
  `:wrap` (see the module docstring).``
  [selected handler &opt opts]
  (default opts {})
  (var h handler)
  (loop [i :down-to [(dec (length selected)) 0]]
    (set h (((selected i) :wrap) h opts)))
  h)

# -- the built-ins -------------------------------------------------------

(defn panic-guard
  {:params [] :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
  ``Log a failed delivery with everything needed to find it again —
  the handler, the topic, the message id, the correlation id — and
  re-raise, because what a failure *means* is the backend's declared
  guarantee and this middleware has no business deciding it.``
  []
  {:name :bus/panic-guard
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
                      # errors/str, not describe: since 8.1 what a handler
                      # raises is usually an envelope, and "<struct 0x…>"
                      # is not a line anyone can act on
                      :err (errors/str err))
           (propagate err fib)))))})

(defn correlation
  {:params [] :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
  ``Bind the message's correlation and causation onto the fiber and
  into the log context, so that everything the handler does — every
  log line, every message it publishes in turn — carries the same
  thread back to the request that started it.

  This is the whole of "context propagation" for the ninety per cent
  of it that is not a trace: it needs no exporter, no collector and no
  `void/obs` in the composition.``
  []
  {:name :bus/correlation
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
  {:params [{:parse (fn [:any] :any) :with-span (fn [:any :any :any] :any) & r}]
   :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
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

(defn- backoff-delay
  {:params [{:base :number? :max :number? :jitter :number? :strategy :keyword? & r} :number]
   :ret :number}
  "The delay before the next retry attempt, with jitter: `cfg`'s
  `:strategy` (`:fixed`, `:linear` or the exponential default), capped
  at `:max` and nudged by a random fraction of `:jitter` so retries
  from many consumers do not all wake up on the same tick."
  [cfg attempt]
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
  {:params [{:attempts :number? :base :number? :max :number? :jitter :number?
             :strategy :keyword? & r}]
   :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
  ``Try the rest of the chain again, `:attempts` times, with backoff
  and jitter. On the last failure the error is re-raised, which is
  what puts the message in front of the poison middleware and, under
  an at-least-once backend, back in the log.

  `cfg`: `{:attempts 3 :strategy :exponential :base 0.2 :max 30
  :jitter 0.25}`.``
  [cfg]
  {:name :bus/retry
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
  {:params [{:max-attempts :number? :topic :keyword? & r} (fn [:any :any :any] :any)]
   :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
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
  {:params [] :ret {:name :keyword :doc :string
                     :when (fn [:any] :boolean) :wrap (fn [:any :any] :any)}}
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
  {:params [{:window :number? & r}]
   :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
  ``Deliver a message id once per window. The seen-set is a table in
  this process's heap with a coarse two-generation expiry: ids move
  into a cold half when the window turns and are dropped when it turns
  again, so the memory is bounded by the arrival rate and the check
  stays two lookups.

  Per process, and `void bus stats` says so — see the module
  docstring for the duplicate this is actually for.``
  [cfg]
  {:name :bus/dedup
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
  {:params [{:max :number? :window :number? & r}]
   :ret {:name :keyword :doc :string :wrap (fn [:any :any] :any)}}
  ``Hold a consumer to `:max` messages per `:window` seconds, by
  sleeping before the handler rather than by dropping: a bus consumer
  that is being paced has somewhere to wait — the log it is reading
  from — which is exactly what an HTTP request does not have, and why
  this is a throttle and `void/security`'s is a limiter.``
  [cfg]
  {:name :bus/throttle
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
