### void/obs/trace — spans, and the context that travels with them
### (SPEC.md §5.13, ROADMAP 3.1).
###
### **A span lives in a dyn, and that is the whole propagation
### mechanism.** ev fibers are the unit of a request in void (ADR-0010),
### dyns are per-fiber, and a fiber's children inherit them — so
### "the current span" needs no thread-local trickery, no context
### argument threaded through every signature, and no leak between two
### requests that happen to be in flight at once. Handing work to
### `ev/go` is the one case dyns do not cover (a task fiber starts with
### a fresh dyn table), and `trace/carrying` is the same answer
### `log/carrying` gives for the log context.
###
### **Ids are minted, not randomised per span.** A trace id is 16
### bytes and a span id is 8, as W3C requires, but generating them from
### `os/cryptorand` per request would put a syscall on the hot path for
### an identifier that only has to be unique, never unguessable. So
### each is a per-process random prefix plus a counter — fastify's
### genReqId model, which void/http already uses for the request id —
### and the prefix is what keeps two workers (ADR-0010) or two hosts
### from minting the same id.
###
### **A span is created when something will consume it.** For the
### request root that means: an exporter is configured, an inbound
### `traceparent` says a caller is already tracing this request, or
### `[:obs :trace :always]` asks for one regardless. A process that
### exports nothing and is called by nobody who traces would otherwise
### build a span table, two ids and an attribute map per request for a
### value no code ever reads — the single largest item in what
### instrumentation costs a request (SPEC §8.2 budgets the whole of
### obs at ≤ 7% of throughput). Spans started by hand — `with-span`
### around a query, a job, a cache round trip — are always created:
### asking for one is the consumer.
###
### **Sampling is a head decision, taken once, and inherited.** The
### root span of a request decides: an incoming `traceparent` that says
### sampled is honoured (a caller that decided to trace this request
### gets the whole trace, which is the point of the header), otherwise
### the rate from the route's `:void.obs/sample-rate` or the `[:obs
### :sample-rate]` default rolls the dice. Every child span inherits
### the decision, so a trace is never half-exported. An unsampled span
### is still created — it carries the ids that correlate the logs and
### the ids that go out on an outgoing request — it simply never
### reaches an exporter.
###
### **Where spans go is not this module's business.** `:void.obs/exporter`
### contributions receive every finished sampled span; void/obs ships
### the log exporter, and the OTLP exporter lands in wave 4 on top of
### void/proto (ROADMAP 4.1) as one more contribution rather than as a
### change here.

(import void/core/log :as log)
(import ./metrics :as metrics)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.trace")

# -- ids -----------------------------------------------------------------

(defn- hex-prefix [bytes]
  (string/join (seq [x :in (os/cryptorand bytes)] (string/format "%02x" x))))

(def- trace-prefix (hex-prefix 8))
(def- span-prefix (hex-prefix 2))
(var- trace-counter 0)
(var- span-counter 0)

(defn new-trace-id
  ``A 32-hex-character trace id: this process's random prefix and a
  counter (see the module docstring). One `string/format` and not a
  format plus a concatenation — two ids are minted per request, and
  the allocation each of them does not do is measured in the b1-obs
  bench row.``
  []
  (string/format "%s%016x" trace-prefix (++ trace-counter)))

(defn new-span-id
  "A 16-hex-character span id."
  []
  (string/format "%s%012x" span-prefix (++ span-counter)))

# -- W3C trace context ---------------------------------------------------

(def traceparent-header
  "The W3C header carrying the trace id, the parent span id and the
  sampling decision."
  "traceparent")

(def tracestate-header
  "The vendor state that travels beside it. void adds nothing to it and
  passes it through unchanged — dropping it would break every other
  system in the trace."
  "tracestate")

(def- hex-chars
  (let [t @{}]
    (each c "0123456789abcdefABCDEF" (put t c true))
    (table/to-struct t)))

(defn- hex? [s n]
  (and (string? s) (= n (length s)) (all |(get hex-chars $) s)))

(defn parse-traceparent
  ``Parse a `traceparent` header value:
  `00-<32 hex trace id>-<16 hex parent id>-<2 hex flags>`. Returns
  {:trace-id :parent-id :sampled :version} or nil — a malformed header
  is *ignored*, never an error: an untrusted inbound header that could
  fail a request would be a denial of service with a text editor.``
  [value]
  (when (string? value)
    (def parts (string/split "-" (string/trim value)))
    (when (= 4 (length parts))
      (def [version tid pid flags] parts)
      (when (and (hex? version 2) (hex? tid 32) (hex? pid 16) (hex? flags 2)
                 # all-zero ids are invalid per the spec
                 (not= tid (string/repeat "0" 32))
                 (not= pid (string/repeat "0" 16))
                 # version ff is forbidden; a higher version still
                 # carries these four fields at the front
                 (not= "ff" (string/ascii-lower version)))
        {:version (string/ascii-lower version)
         :trace-id (string/ascii-lower tid)
         :parent-id (string/ascii-lower pid)
         :sampled (odd? (scan-number (string "0x" flags)))}))))

(defn traceparent
  "The `traceparent` header value for a span."
  [span]
  (string "00-" (span :trace-id) "-" (span :span-id) "-"
          (if (span :sampled) "01" "00")))

# -- exporters -----------------------------------------------------------

(var exporters
  ``The `:void.obs/exporter` contributions a finished sampled span is
  handed to, as a tuple of {:name :fn}. Set once at start — the export
  path iterates it per span, so it is a tuple and not a lookup.``
  [])

(defn set-exporters!
  "Install the exporter list (void/obs's :start does this)."
  [contribs]
  (set exporters (tuple ;(or contribs []))))

(def spans-total
  "Finished spans by name and status — the cheapest possible answer to
  'is this instrumented path being taken at all', and it exists whether
  or not anything exports the spans themselves."
  (metrics/counter :void.obs/spans-total
    {:doc "Finished spans"
     :labels [:span :status]}))

(def span-duration
  "How long spans take, by name. RED per route (void/obs-http) is the
  same numbers labelled the way an HTTP dashboard wants them; this one
  covers every other instrumented path — a query, a job, a cache
  round trip."
  (metrics/histogram :void.obs/span-duration-seconds
    {:doc "Span duration in seconds"
     :labels [:span]}))

# -- the span itself -----------------------------------------------------

(def span-dyn
  "Dynamic binding: the span the current fiber is inside."
  :void.obs/span)

(var enabled
  "Is tracing on? A module var, so a process with tracing off pays one
  deref per instrumented call site."
  false)

(var always
  ``Create a request's span even when nothing consumes it
  (`[:obs :trace :always]`). Off by default: with no exporter
  configured and no inbound `traceparent`, a root span is a table
  nobody reads, and building one per request is the largest single
  item in what obs costs a request (the b1-obs bench row). Turn it on
  to have trace ids in every log record of a process that exports
  nothing — void/http's request id already correlates a single
  process's records, and a trace id is what correlates *several*.``
  false)

(var default-sample-rate
  "The head sampling rate when nothing more specific applies ([:obs
  :sample-rate])."
  1.0)

(defn current
  "The span this fiber is inside, or nil."
  []
  (dyn span-dyn))

(defn context
  ``The correlation ids of the current span, as the log context wants
  them: {:trace-id ... :span-id ...}, or {} outside a span. This is
  the seam ROADMAP 3.1 asks for in the logs line — void/core/log
  (ADR-0018) already binds a context per fiber, and obs puts the trace
  ids into it.``
  [&opt span]
  (default span (current))
  (if span
    {:trace-id (span :trace-id) :span-id (span :span-id)}
    {}))

(defn sample?
  "Roll the head sampling decision at `rate` (nil = the configured
  default)."
  [&opt rate]
  (def r (if (nil? rate) default-sample-rate rate))
  (cond
    (>= r 1) true
    (<= r 0) false
    (< (math/random) r)))

(defn start
  ``Start a span and return it. Options:

    :parent      an explicit parent span (default: the fiber's current)
    :remote      a parsed traceparent ({:trace-id :parent-id :sampled})
                 from an inbound request — makes this span the local
                 root of somebody else's trace
    :kind        :server :client :internal :producer :consumer
    :attrs       initial attributes (a dictionary)
    :sample-rate the head rate, when this span is a root
    :sampled     force the decision (a test, a debug endpoint)

  Starting a span does not bind it — `with-span` does that, and
  `end!` closes it.``
  [name &opt opts]
  (default opts {})
  (def parent (if (has-key? opts :parent) (opts :parent) (current)))
  (def remote (opts :remote))
  (def sampled
    (cond
      (not (nil? (opts :sampled))) (opts :sampled)
      parent (parent :sampled)
      remote (remote :sampled)
      (sample? (opts :sample-rate))))
  @{:name name
    :trace-id (cond
                parent (parent :trace-id)
                remote (remote :trace-id)
                (new-trace-id))
    :span-id (new-span-id)
    :parent-id (cond
                 parent (parent :span-id)
                 remote (remote :parent-id))
    :remote (truthy? remote)
    :kind (get opts :kind :internal)
    :sampled (truthy? sampled)
    :start (os/clock :monotonic)
    :started-at (os/clock :realtime)
    # a table the caller built for this span is taken as it is: the
    # request middleware allocates one per request either way, and a
    # defensive copy of it would be a second one
    :attrs (let [a (get opts :attrs)]
             (cond
               (table? a) a
               (nil? a) @{}
               (merge @{} a)))
    :status :ok})

(defn attr!
  ``Add an attribute to a span (default: the current one). Attributes
  are what makes a trace searchable — the route, the SQL statement
  kind, the job queue.``
  [key value &opt span]
  (default span (current))
  (when span (put (span :attrs) key value))
  value)

(defn error!
  "Mark a span failed, with the error value as an attribute."
  [err &opt span]
  (default span (current))
  (when span
    (put span :status :error)
    (put (span :attrs) :error (if (bytes? err) (string err) (describe err))))
  err)

(defn end!
  ``Finish a span: stamp its duration, count it, and hand it to the
  exporters when it was sampled. An exporter that throws is logged and
  the rest still run — a broken exporter may not fail the request it
  was watching.``
  [span &opt opts]
  (when (and span (not (span :ended)))
    (put span :ended true)
    (when-let [s (get opts :status)] (put span :status s))
    (when-let [a (get opts :attrs)] (merge-into (span :attrs) a))
    (def dur (- (os/clock :monotonic) (span :start)))
    (put span :duration dur)
    # the label values go in as they are — a keyword status and a
    # string name both render as text in the exposition
    # (prometheus/escape-label), and converting them here would be two
    # allocations per span for a string nobody reads between scrapes
    (metrics/inc! spans-total [(span :name) (span :status)])
    (metrics/observe! span-duration [(span :name)] dur)
    (when (span :sampled)
      (each e exporters
        (def [ok err] (protect ((e :fn) span)))
        (unless ok
          (log/warn "span exporter failed" :ns log-ns
                    :exporter (e :name)
                    :err (if (string? err) err (describe err)))))))
  span)

(defn with-span*
  ``The function behind `with-span` — a span around a thunk. The span
  ends when the thunk does, including when it throws: the span is
  marked failed and the error is re-raised with `propagate`, so the
  fiber — and with it the stacktrace the dev error page and the :err
  log serializer print — reaches the panic guard exactly as it would
  have without the span.``
  [name opts f]
  (def span (start name opts))
  (with-dyns [span-dyn span]
    (log/with-context (context span)
      (try
        (let [out (f)]
          (end! span)
          out)
        ([err fib]
          (error! err span)
          (end! span)
          (propagate err fib))))))

(defmacro with-span
  ``Run `body` inside a span, with the trace ids bound to the log
  context for its whole extent:

      (trace/with-span "orders.load" {:attrs {:db.system "postgres"}}
        (db/query ...))

  See `with-span*` for what happens when the body throws.``
  [name opts & body]
  ~(,with-span* ,name ,opts (fn with-span-body [] ,;body)))

(defn carrying
  "Wrap `f` so it runs inside the span bound at wrap time — for work
  handed to `ev/go`, whose fibers do not inherit dyns (the same answer
  `log/carrying` gives for the log context)."
  [f]
  (def span (current))
  (fn carried [& args]
    (with-dyns [span-dyn span]
      (log/with-context (context span)
        (f ;args)))))

# -- outbound propagation ------------------------------------------------

(defn inject!
  ``Write the current trace context into an outgoing request's header
  table and return it:

      (trace/inject! @{"content-type" "application/json"})

  This is the "traceparent out" half of ROADMAP 3.1 — the half that
  does not need an HTTP client of our own (void has none yet; the
  point of the exercise is that whatever makes the call, from
  void/redis to a future void/http-client, propagates the context with
  one call).``
  [headers &opt span]
  (default span (current))
  (when span
    (put headers traceparent-header (traceparent span))
    (when-let [ts (span :tracestate)]
      (put headers tracestate-header ts)))
  headers)

(defn headers
  "The trace-context headers for the current span as a fresh table."
  [&opt span]
  (inject! @{} span))
