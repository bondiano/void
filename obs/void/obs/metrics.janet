### void/obs/metrics — the metric registry (SPEC.md §5.13).
###
### Three instrument kinds, the Prometheus data model and nothing
### else: a counter only goes up, a gauge is a number right now, a
### histogram is bucket counts plus a sum. Anything a dashboard,
### an alert or an exporter wants is one of those three, and a fourth
### shape would have to be translated into them at every exporter
### anyway.
###
### **Declared once, at module load; written on the hot path.** A
### metric is declared by the code that owns it — `(metrics/counter
### :void.http/requests-total {...})` at the top of a module — and the
### declaration returns a handle. Writing is then a table lookup on a
### tuple of label values and a number update: no name parsing, no
### registry lookup, no allocation per observation once a label set has
### been seen. Re-declaring the same metric (a REPL redefinition, a
### `dofile` reload from the dev watcher, ADR-0002) returns the
### *existing* handle with its values intact, rather than resetting a
### counter because a file was saved.
###
### **Label sets are capped, and the cap is the feature.** Cardinality
### is how metrics take a process down: one label carrying a user id or
### a raw path turns a fixed-size registry into an unbounded one, and
### the failure lands as memory exhaustion in production rather than as
### a mistake at review. So a metric refuses label sets past
### `:max-label-sets`, counts what it refused in
### `:void.obs/metrics-dropped-total`, and says which metric did it in
### the log — once per metric, because a message per dropped
### observation would be the same unbounded write in another file. This
### is why RED metrics are labelled by *route name* (a route table is
### finite) and never by request path.
###
### Gauges may be **pull-based**: a `:collect` thunk is called at
### scrape time and returns a number, or a list of [labels value]
### pairs. That is how pool sizes, RSS and component health reach the
### exposition without a sampler fiber writing numbers nobody reads
### between two scrapes.

(import void/core/log :as log)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.metrics")

(def kinds
  "The instrument kinds, and what each one means to an exporter."
  {:counter "monotonic total"
   :gauge "value right now"
   :histogram "bucket counts + sum"})

(def default-buckets
  ``Default histogram boundaries, in **seconds** — Prometheus base
  units, so an exporter never converts and a dashboard never guesses.
  The spread covers a void request end to end: the §8.2 budgets live
  between 1 and 20 ms, so the resolution is there, and the tail runs
  out to 10 s because a request that takes that long is the one being
  investigated.``
  [0.001 0.0025 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5 10])

(def default-max-label-sets
  "How many distinct label sets one metric may hold before it refuses
  new ones (see the module docstring)."
  1000)

# -- the registry --------------------------------------------------------

(def registry
  ``Metric name -> handle. Process-wide and populated at module load
  time, like the log level tree: metrics are declared by the module
  that owns them, before any boot exists, and a handle outlives a
  system restart the way a counter should.``
  @{})

(var- max-label-sets default-max-label-sets)

(defn set-max-label-sets!
  "Set the per-metric label-set cap (config [:obs :max-label-sets])."
  [n]
  (set max-label-sets n))

(def no-labels
  "The key of the single series of a metric with no labels."
  [])

(defn- as-key [labels]
  (cond
    (nil? labels) no-labels
    (tuple? labels) labels
    (indexed? labels) (tuple ;labels)
    # a bare value is the one-label sugar: (inc! m :get)
    [labels]))

(defn- check-spec [name existing kind label-names]
  (unless (= kind (existing :kind))
    (errorf "metric %q is already declared as a %q, not a %q"
            name (existing :kind) kind))
  (unless (= label-names (existing :labels))
    (errorf "metric %q is already declared with labels %q, not %q"
            name (existing :labels) label-names))
  existing)

(defn- declare! [name kind opts]
  (unless (keyword? name)
    (errorf "metric name must be a keyword, got %q" name))
  (def label-names (tuple ;(get opts :labels [])))
  (unless (all keyword? label-names)
    (errorf "metric %q: :labels must be keywords, got %q" name label-names))
  (if-let [existing (get registry name)]
    # a redeclaration is a reload, not a reset (see the module docstring)
    (check-spec name existing kind label-names)
    (let [m @{:name name
              :kind kind
              :doc (get opts :doc "")
              :labels label-names
              :values @{}
              :dropped 0
              :warned false}]
      (when (= :histogram kind)
        (put m :buckets (tuple ;(sorted (get opts :buckets default-buckets)))))
      (when-let [c (get opts :collect)]
        (put m :collect c))
      (put registry name m)
      m)))

(defn counter
  ``Declare a counter — a total that only goes up (requests, errors,
  jobs completed):

      (def requests (metrics/counter :void.http/requests-total
                      {:doc "HTTP requests" :labels [:route :method :status]}))``
  [name &opt opts]
  (declare! name :counter (or opts {})))

(defn gauge
  ``Declare a gauge — a number that goes both ways (in-flight requests,
  pool size, RSS). With `:collect` it is pull-based: the thunk is
  called at scrape time and returns a number or a list of
  [labels value] pairs.``
  [name &opt opts]
  (declare! name :gauge (or opts {})))

(defn histogram
  ``Declare a histogram — a distribution in bucket counts plus a sum
  (durations, sizes). `:buckets` are upper bounds in seconds
  (`default-buckets`).``
  [name &opt opts]
  (declare! name :histogram (or opts {})))

(defn find-metric
  "The handle registered under `name`, or nil."
  [name]
  (get registry name))

(defn set-collector!
  ``Attach (or, with nil, detach) a metric's pull source after
  declaration — how an instrumentation hands a metric a number it does
  not own (`:void.obs/instrument`, ./instrument): the pool exists only
  once the component is started, and the metric is declared at module
  load. A detached metric keeps its declaration and reports no series,
  which is what a stopped pool honestly looks like.``
  [m collect]
  (put m :collect collect)
  m)

# -- writing -------------------------------------------------------------

(defn- refuse! [m key]
  (update m :dropped inc)
  (unless (m :warned)
    (put m :warned true)
    (log/warn "metric label cardinality capped — further label sets are dropped"
              :ns log-ns :metric (m :name) :cap max-label-sets
              :labels (m :labels) :example key))
  nil)

(defn- room? [m key]
  (or (< (length (m :values)) max-label-sets)
      (refuse! m key)))

(defn inc!
  ``Add to a counter (default 1):

      (metrics/inc! requests [route method status])

  `labels` is a tuple of label values in declared order, nil for a
  metric with none, or a bare value for a single-label metric.``
  [m &opt labels n]
  (def key (as-key labels))
  (def by (if (nil? n) 1 n))
  (if-let [v (get (m :values) key)]
    (put (m :values) key (+ v by))
    (when (room? m key)
      (put (m :values) key by)))
  nil)

(defn set!
  "Set a gauge's value for a label set."
  [m &opt labels v]
  (def key (as-key labels))
  (if (or (has-key? (m :values) key) (room? m key))
    (put (m :values) key (if (nil? v) 0 v))
    nil)
  nil)

(defn add!
  "Add to a gauge (a negative number subtracts) — the in-flight idiom."
  [m &opt labels n]
  (def key (as-key labels))
  (def by (if (nil? n) 1 n))
  (if-let [v (get (m :values) key)]
    (put (m :values) key (+ v by))
    (when (room? m key)
      (put (m :values) key by)))
  nil)

(defn- new-series [m]
  @{:buckets (array/new-filled (length (m :buckets)) 0)
    :sum 0
    :count 0})

(defn observe!
  ``Record one observation in a histogram — `v` in seconds:

      (metrics/observe! duration [route method] 0.0031)``
  [m &opt labels v]
  (def key (as-key labels))
  (def x (if (nil? v) 0 v))
  (def series
    (or (get (m :values) key)
        (when (room? m key)
          (let [s (new-series m)] (put (m :values) key s) s))))
  (when series
    (def bounds (m :buckets))
    # linear scan over a dozen bounds: fewer comparisons than a binary
    # search sets up, and the buckets are sorted by declaration
    (var i 0)
    (def n (length bounds))
    (while (and (< i n) (> x (in bounds i))) (++ i))
    (when (< i n)
      (put (series :buckets) i (inc (in (series :buckets) i))))
    (put series :sum (+ (series :sum) x))
    (put series :count (inc (series :count))))
  nil)

(defn value
  "The current value of one series: a number (counter/gauge) or the
  histogram series table. nil when that label set has none yet."
  [m &opt labels]
  (get (m :values) (as-key labels)))

(defn quantile
  ``An approximate quantile of a histogram series — the same
  computation `histogram_quantile()` does in Prometheus: find the
  bucket the rank falls into and interpolate linearly inside it.

      (metrics/quantile duration 0.99 [route])

  It is the exposition's own resolution, not a second data structure:
  a histogram *is* bucket counts, and a p99 read off one is exact to
  the width of a bucket and no better. Observations past the last
  bound have no upper edge to interpolate towards, so the last bound
  is returned — a lower bound on the answer, never a number the
  buckets cannot support. nil when the series has no observations.``
  [m q &opt labels]
  (unless (= :histogram (m :kind))
    (errorf "quantile: %q is a %q, not a histogram" (m :name) (m :kind)))
  (def s (get (m :values) (as-key labels)))
  (when (and s (pos? (s :count)))
    (def bounds (m :buckets))
    (def counts (s :buckets))
    (def rank (* q (s :count)))
    (var cum 0)
    (var lower 0)
    (var out nil)
    (var i 0)
    (def n (length bounds))
    (while (and (nil? out) (< i n))
      (def upper (in bounds i))
      (def acc (+ cum (in counts i)))
      (if (>= acc rank)
        (set out (if (> acc cum)
                   (+ lower (* (- upper lower) (/ (- rank cum) (- acc cum))))
                   upper))
        (do (set cum acc)
            (set lower upper)
            (++ i))))
    (or out (last bounds))))

# -- reading -------------------------------------------------------------

(defn- collected-series [m]
  (def out @[])
  (def [ok v] (protect ((m :collect))))
  (cond
    (not ok)
    (log/warn "metric collector failed" :ns log-ns :metric (m :name)
              :err (if (string? v) v (describe v)))

    (number? v)
    (array/push out {:labels no-labels :value v})

    (indexed? v)
    (each pair v
      (when (and (indexed? pair) (= 2 (length pair)))
        (array/push out {:labels (as-key (in pair 0)) :value (in pair 1)})))

    (dictionary? v)
    (eachp [k n] v
      (array/push out {:labels (as-key k) :value n})))
  out)

(defn- series-of [m]
  (if (m :collect)
    (collected-series m)
    (seq [k :in (sorted (keys (m :values)))]
      (def v (get (m :values) k))
      (if (= :histogram (m :kind))
        {:labels k
         :buckets (tuple ;(v :buckets))
         :sum (v :sum)
         :count (v :count)}
        {:labels k :value v}))))

(defn snapshot
  ``Every metric as data, sorted by name — what an exporter renders
  and what `(obs/metrics)` returns in the REPL. Pull-based gauges are
  collected here, so this is the only place a scrape costs anything.``
  []
  (seq [name :in (sorted (keys registry))]
    (def m (get registry name))
    (def out @{:name name
               :kind (m :kind)
               :doc (m :doc)
               :labels (m :labels)
               :dropped (m :dropped)
               :series (series-of m)})
    (when (= :histogram (m :kind))
      (put out :buckets (m :buckets)))
    (table/to-struct out)))

(defn reset!
  ``Drop every recorded value, keeping the declarations — what a test
  calls between cases. Without `name`, every metric.``
  [&opt name]
  (each m (if name [(or (get registry name) (errorf "no metric %q" name))]
              (values registry))
    (table/clear (m :values))
    (put m :dropped 0)
    (put m :warned false))
  nil)

(defn clear-registry!
  "Forget every declaration — for tests that redeclare metrics with
  different labels. Live handles keep working; they are simply no
  longer in the exposition."
  []
  (table/clear registry)
  nil)

# -- the registry's own numbers ------------------------------------------

(def dropped
  "Observations refused by the cardinality cap, by metric — the number
  that turns 'the dashboard is missing rows' into 'this metric is
  over-labelled'."
  (gauge :void.obs/metrics-dropped-total
    {:doc "Observations dropped because a metric hit :max-label-sets"
     :labels [:metric]
     :collect (fn collect-dropped []
                (seq [name :in (sorted (keys registry))
                      :let [m (get registry name)]
                      :when (pos? (m :dropped))]
                  [[(string name)] (m :dropped)]))}))

(def series-count
  "How many label sets each metric holds — the early warning the cap
  turns into a refusal."
  (gauge :void.obs/metrics-series
    {:doc "Label sets held per metric"
     :labels [:metric]
     :collect (fn collect-series []
                (seq [name :in (sorted (keys registry))]
                  [[(string name)] (length (get-in registry [name :values]))]))}))
