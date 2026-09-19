# Types of void/obs's values, named where they recur.

# What a span is to its peers (OpenTelemetry's span kind).
(def ObsSpanKind :typedef
  '(enum :server :client :internal :producer :consumer))

# A span: the table `trace/start` builds; `end!` adds `:ended` and `:duration`, an inbound
# traceparent `:tracestate` — and a caller may add its own keys, hence open.
(def ObsSpan :typedef
  '@{:name :string :trace-id :string :span-id :string :parent-id :string?
       :remote :boolean :kind ObsSpanKind :sampled :boolean
       :start :number :started-at :number :attrs @{:any :any} :status :keyword
       :ended :boolean? :duration :number? :tracestate :string? & r})

# The options `trace/start` and `with-span*` read.
(def ObsSpanOptions :typedef
  '{:parent (or @{:trace-id :string :span-id :string :sampled :boolean & r} :nil)
    :remote (or {:trace-id :string :parent-id :string :sampled :boolean & r} :nil)
    :kind ObsSpanKind
    :attrs @{:any :any}
    :sample-rate :number
    :sampled :boolean
    & r})

# A metric handle: the table `metrics/declare!` registers — a counter, gauge or histogram
# and its series; `:buckets` and `:collect` when declared with them — hence open.
(def ObsMetric :typedef
  '@{:name :keyword :kind (enum :counter :gauge :histogram) :doc :string :labels :tuple
       :values @{:tuple :any} :dropped :number :warned :boolean & r})

# The options `metrics/counter`, `gauge` and `histogram` read.
(def ObsMetricOptions :typedef
  '{:doc :string? :labels (or [:keyword] :nil) :buckets (or [:number] :nil)
    :collect (or (fn [] :any) :nil) & r})
