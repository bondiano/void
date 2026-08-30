### void/grpc/mount — a method is a route (SPEC.md §5.8, ADR-0005,
### ADR-0013).
###
### The projection, and the whole architectural claim of this package.
### Every registered method becomes a real route in the one route
### table — named, with metadata, in `void routes`, visible to
### `explain-route`:
###
###     POST /shop.orders.OrderService/GetOrder   :shop.orders.OrderService/GetOrder
###
### So `:void.authz/policy` on an RPC method is the same key, checked
### by the same middleware in the same phase, as on a page.
### `:void.db/txn` opens the same transaction. void/obs' RED metrics
### label it by route name. void/security's headers and limits are in
### front of it. void/pressure sheds it. **Nothing in this package
### re-implements any of that**, which is the payoff ADR-0013 promised
### for choosing Connect over HTTP/1.1 instead of a second server.
###
### A method's route metadata is the service's layer merged with the
### method's, through the router's own group -> route merge — so
### "every method needs this policy, except this one which needs a
### stricter one" is written the way it is written for pages.
###
### An idempotent method (`idempotency_level = NO_SIDE_EFFECTS` in the
### `.proto`) also gets a GET route. That is Connect's own design, and
### it is what puts an RPC method within reach of `:void.cache/response`
### and of every cache between here and the client.

(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/proto/descriptor :as desc)
(import ./codes :as codes)
(import ./connect :as connect)
(import ./service :as service)

(var codecs-ref
  "The resolved :void.grpc/codec point, set at :before-start — one per
  process, like plugin/current-boot."
  [])

(var settings-ref
  "The [:grpc] slice, set at :before-start."
  {})

(var detail-encoder
  "How an error detail becomes a Connect `details` entry. Set by
  ./init, which is where void/proto is imported."
  (fn [detail] detail))

(def call-dyn
  ``Where the call being answered lives while a handler runs:
  {:service :method :descriptor :codec :req}. A handler is given its
  message and the request and needs nothing else; this is for the
  layer under it — a logger, a policy, an interceptor an application
  wrote — that wants to know which method it is inside without being
  passed it.``
  :void.grpc/call)

(defn current-call
  "The call this fiber is answering, or nil."
  []
  (dyn call-dyn))

# -- one call -------------------------------------------------------------

(defn- run-handler
  ``Call the handler, honouring the client's `Connect-Timeout-Ms`.

  With a deadline the call runs as its own task, so the deadline
  cancels *that* and never the fiber underneath — the same shape
  void/http's `run-handler` uses, and for the same upstream reason
  (ADR-0015, janet-lang/janet#1337).``
  [call handler message req timeout]
  (defn invoke [] (with-dyns [call-dyn call] (handler message req)))
  (if (nil? timeout)
    (invoke)
    (do
      (def sup (ev/chan 1))
      (def task (ev/go (fn handler-task [] (invoke)) nil sup))
      (ev/deadline timeout task task)
      (def [sig fib] (ev/take sup))
      (def value (fiber/last-value fib))
      (cond
        (= :ok sig) value
        (and (string? value) (string/find "deadline" value))
        (codes/fail! :deadline_exceeded
                     (string/format "the client's Connect-Timeout-Ms of %d ms ran out"
                                    (math/round (* 1000 timeout))))
        (error value)))))

(defn- panic-message
  ``What a client is told when a handler raised something that is not
  an RPC failure. In :prod that is a sentence and nothing else: an
  unhandled error's text is a stack of somebody's internals, and the
  place for it is the log, which the kernel's own error path has
  already written to.``
  [err]
  (if (get settings-ref :describe-errors)
    (if (string? err) err (string/format "%q" err))
    "the server failed to answer this call"))

(defn answer
  ``Answer one Connect call against a service and a method. Public
  because it is the whole protocol in one function, and a test that
  wants to drive it without a route table can.``
  [svc m handler req]
  (def codecs codecs-ref)
  (def [ok result]
    (protect
      (do
        (connect/check-encoding! req)
        (def get? (= :get (req :method)))
        (unless get?
          (connect/check-protocol-version!
            req (truthy? (get settings-ref :require-protocol-version))))
        (def [codec bytes]
          (if get?
            (connect/read-get req codecs)
            (connect/read-post req codecs)))
        (def message (connect/decode-message codec (m :input) bytes))
        (def call {:service (svc :name) :method (m :name)
                   :descriptor m :codec (codec :name) :req req})
        (def out (run-handler call handler message req (connect/timeout-of req)))
        (def [value meta]
          (if (connect/response? out)
            [(out :message) out]
            [out {}]))
        (unless (dictionary? value)
          (error (codes/error-value
                   :internal
                   (string/format "%q returned %q — an rpc handler returns its response message (or grpc/respond)"
                                  (m :route-name) value))))
        (connect/ok-response codec (m :output) value meta))))
  (if ok
    result
    (if-let [failure (codes/failure result (panic-message result))]
      (connect/error-response failure detail-encoder)
      # a raised dictionary that is neither an RPC failure nor an HTTP
      # abort belongs to somebody else — the kernel's error renderers
      # get their turn
      (error result))))

(defn- env-of
  ``The declaring module's environment. `defservice` stores it wrapped
  in `router/env-ref` for the same reason a route source does: a
  service value is frozen, and freezing a raw env table would walk the
  entire module graph, cycles included.``
  [svc]
  (def env (svc :env))
  (if (function? env) (env) env))

(defn- resolve-handler [svc m]
  (router/resolve-callable (m :handler) (env-of svc)
                           (string/format "rpc %q" (m :route-name))))

(defn handler-for
  "The route handler of one method — a closure over the service, the
  method and the handler resolved against the declaring module's
  environment (late binding, ADR-0002)."
  [svc m]
  (def handler (resolve-handler svc m))
  (fn rpc-route [req] (answer svc m handler req)))

# -- the route table ------------------------------------------------------

(defn method-meta
  ``The metadata one method's *route* carries. The service's own layer
  is not merged in here: it is the route group's, and merging it is
  the router's job — with provenance, and with `:restrict` keys that
  may only be tightened (ADR-0005). Two merges that could disagree is
  one merge too many.``
  [svc m]
  (merge {:name (m :route-name)
          :void.grpc/service (svc :name)
          :void.grpc/method (m :name)}
         (m :meta)))

(defn routes
  ``Every registered service, as routes. A function rather than a
  value, because the registry it projects is filled by the
  application's own modules long after this plugin's manifest froze —
  the same reason void/admin's route source is a function
  (:void.http/route-source in void/http).``
  []
  (def children @[])
  (each svc (service/services)
    (def group-children @[])
    (each m (svc :methods)
      (def h (handler-for svc m))
      (def meta (method-meta svc m))
      (array/push group-children (router/POST (m :path) h meta))
      (when (m :idempotent)
        # Connect's GET form, for a method whose .proto said it has no
        # side effects. A cache in front of this route now has
        # something it can do — and it is a route of its own, with a
        # name of its own (see service/get-route-name)
        (array/push group-children
                    (router/GET (m :path) h
                                (merge meta {:name (service/get-route-name
                                                     (svc :proto-name) (m :proto-name))})))))
    (array/push children (router/group "" (svc :meta) ;group-children)))
  (router/routes {} ;children))

(defn describe
  ``Every mounted method as a line — what `void grpc services` prints
  and what a test asserts the projection produced.``
  []
  (seq [svc :in (service/services) m :in (svc :methods)]
    {:service (svc :name)
     :method (m :name)
     :path (m :path)
     :route (m :route-name)
     :get-route (when (m :idempotent)
                  (service/get-route-name (svc :proto-name) (m :proto-name)))
     :input (m :input)
     :output (m :output)
     :idempotent (truthy? (m :idempotent))
     :meta (method-meta svc m)
     :service-meta (svc :meta)}))
