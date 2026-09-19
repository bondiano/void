# Types of void/bus's values, named where they recur.

# -- messages ------------------------------------------------------------

# A message: the table `message/make` builds over its payload, `a`. The meta carries the
# framework's keys (`:published-at`, `:correlation-id`, …) beside the application's own.
(def BusMessage :typedef {:of [a]}
  '@{:id :string :topic :keyword :payload a :meta @{:keyword :any}})

# What a handler is: called with the delivered message; returning is an ack, throwing a nack.
(def BusHandler :typedef
  '(fn [BusMessage] :any))

# A message with its payload and meta already through the codec: what a backend's
# `:publish!` is handed (void/bus/backend's docstring).
(def BusEnvelope :typedef
  '{:id :string :topic :keyword :body :any :meta-body :any :meta {:keyword :any} & r})

# -- backends ------------------------------------------------------------

# What a backend promises, filled in and checked by `backend/normalize`.
(def BusGuarantees :typedef
  '{:delivery (enum :at-most-once :at-least-once)
   :ordering (enum :none :per-group)
   :durable :boolean
   :shared :boolean})

# A backend after `backend/normalize`: every optional key filled in, so the router calls
# each unconditionally; plus anything of the backend's own — hence open.
(def BusBackend :typedef
  '{:name :keyword :encoded? :boolean
   :stats (fn [] :any) :health (or (fn [] :any) :nil) :close (fn [] :any)
   :publish! (fn [BusEnvelope] :any)
   :consume! (fn [{:group :keyword :topics [:any] & r} (fn [:any] :any)] :any)
   :stop! (fn [:any] :any)
   :guarantees BusGuarantees & r})

# A codec after `codec/normalize`: how a payload and a meta table become what an encoded
# backend stores, and back.
(def BusCodec :typedef
  '{:name :keyword :bytes? :boolean :doc :any
   :encode (fn [:any] :any) :decode (fn [:any] :any) & r})

# -- middleware ----------------------------------------------------------

# A :void.bus/middleware contribution after `middleware/normalize`: `:wrap` takes the handler
# and the handler's own options and answers the wrapped handler; `:after`/`:before` place it
# against the chain's anchors or a neighbour, and `:plugin` is who contributed it.
(def BusMiddleware :typedef
  '{:name :keyword :wrap (fn [:any :any] :any)
   :after (or :keyword [:keyword] :nil) :before (or :keyword [:keyword] :nil)
   :plugin :keyword?
   :doc :any :named :boolean :when (or (fn [:any] :boolean) :nil) & r})

# The tracing seam void/obs fills: a span around a delivery, and the W3C traceparent a
# message carries.
(def BusTracer :typedef
  '{:with-span (fn [:any :any :any] :any) :parse (fn [:any] :any) :traceparent (fn [] :any)})

# A broker: the table `state/make` builds over a normalized backend and codec — what the
# :bus/broker component holds and every publish and consumer runs against.
(def BusBroker :typedef
  '@{:backend BusBackend :codec BusCodec
    :config {:group :keyword? & r} :group :keyword
    :chain [BusMiddleware]
    :tracer BusTracer?
    :consumers @{:keyword :any}
    :outbox (or (fn [:any] :any) :nil)
    :stats @{:published :number :delivered :number :outboxed :number}})
