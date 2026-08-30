### void/grpc/service — an RPC service as a value (SPEC.md §5.8,
### ADR-0013, ADR-0004).
###
### `defservice` binds handlers to a service descriptor void/proto
### already has — from a `.proto` file, or declared in Janet. It adds
### *nothing* to the shape: the methods, their input and output
### messages and whether they have side effects were all said once, in
### the file, and saying them again here is how two declarations
### start to disagree.
###
###     (proto/defproto "protos/orders.proto")
###
###     (grpc/defservice :shop.orders/OrderService
###       {:meta {:void.authz/policy :orders/may-call}}
###       (rpc :GetOrder get-order)
###       (rpc :ListOrders list-orders)
###       (rpc :PlaceOrder place-order {:void.db/txn true}))
###
### What it does add is the two things a `.proto` cannot say: which
### Janet function answers a method, and what route metadata it
### carries — the same metadata an HTTP route carries, because
### ./mount turns each method into a real route (ADR-0005, and the
### promise ADR-0013 makes about one stack of policies).
###
### **A missing handler is a boot error.** A service that answers
### `unimplemented` for a method its own `.proto` declares is a
### service whose contract is a lie in one spot, and the client that
### finds out is the one debugging it. So every method is bound here
### or the declaration fails, naming the method.
###
### **A streaming method is refused here, too.** Not at call time: at
### declaration, where the person reading the error is the person who
### can change the `.proto` or wait for v2 (ADR-0013).
###
### The registry holds *values*, the way void/admin's resource
### registry does — so ./mount can project it into routes and the CLI
### can print it without either of them being the other's caller.

(import void/proto/descriptor :as desc)
(import void/http/router :as router)

(defn- callable? [x] (or (function? x) (cfunction? x)))

(defn path-of
  "The path a Connect call to this method arrives on."
  [service-proto-name method-proto-name]
  (string "/" service-proto-name "/" method-proto-name))

(defn route-name
  "The route name a method's route carries — `:shop.orders.OrderService/GetOrder`,
  so `void routes` and `explain-route` name an RPC method the way its
  clients do."
  [service-proto-name method-proto-name]
  (keyword service-proto-name "/" method-proto-name))

(defn get-route-name
  ``The name of the *second* route an idempotent method gets — Connect's
  GET form, which is a route of its own and so needs a name of its own.
  A protobuf identifier cannot contain a dash, so this suffix can
  collide with no method anybody could declare; and having two names
  rather than one is what lets void/obs count the cached half of a
  method's traffic separately from the rest.``
  [service-proto-name method-proto-name]
  (keyword service-proto-name "/" method-proto-name "-get"))

(defn method
  ``Normalize one method binding: {:name :GetOrder :handler <fn or
  symbol> :meta {...}}. The shape comes from the service descriptor,
  so this only carries what the `.proto` could not.``
  [spec]
  (unless (and (dictionary? spec) (keyword? (spec :name)))
    (errorf "void/grpc: an rpc binding needs a keyword :name, got %q" spec))
  (def handler (spec :handler))
  (unless (or (symbol? handler) (callable? handler))
    (errorf "void/grpc: rpc %q needs a handler function or symbol, got %q"
            (spec :name) handler))
  (def meta (get spec :meta {}))
  (unless (dictionary? meta)
    (errorf "void/grpc: rpc %q: :meta must be a metadata dictionary, got %q"
            (spec :name) meta))
  {:name (spec :name) :handler handler :meta meta})

(defn service
  ``Build a service value out of a registered service descriptor and a
  list of method bindings. opts: :meta (route metadata for every
  method — the group layer), :env (`router/env-ref (curenv)` for bare
  handler symbols), :doc.``
  [name bindings &opt opts]
  (default opts {})
  (def d (desc/service! name))
  (def bound (map method bindings))
  (def by-name @{})
  (each b bound
    (when (in by-name (b :name))
      (errorf "void/grpc: service %q binds %q twice" name (b :name)))
    (put by-name (b :name) b))

  (each m (d :methods)
    (when (or (m :client-streaming) (m :server-streaming))
      (errorf (string "void/grpc: %q.%s is a streaming method, and void speaks unary Connect "
                      "over HTTP/1.1 (ADR-0013: streaming needs a transport that keeps two "
                      "directions open, and that is a v2 decision). Serve it as unary, or "
                      "leave the method out of the service void mounts")
              name (m :proto-name)))
    (unless (by-name (m :name))
      (errorf (string "void/grpc: %q declares rpc %s in its .proto and nothing here answers it. "
                      "A service that is unimplemented in one spot is a contract its clients "
                      "cannot read — bind it with (rpc %s <handler>)")
              name (m :proto-name) (m :name))))
  (each b bound
    (unless (get-in d [:by-name (b :name)])
      (errorf "void/grpc: %q has no rpc %q (it has %s)"
              name (b :name)
              (string/join (map |(string ($ :name)) (d :methods)) " "))))

  (def methods
    (seq [m :in (d :methods)]
      (def b (by-name (m :name)))
      (freeze (merge {} m
                     {:handler (b :handler)
                      :meta (b :meta)
                      :service name
                      :service-proto-name (d :proto-name)
                      :path (path-of (d :proto-name) (m :proto-name))
                      :route-name (route-name (d :proto-name) (m :proto-name))}))))
  (freeze
    {:name name
     :descriptor d
     :proto-name (d :proto-name)
     :path (string "/" (d :proto-name))
     :meta (get opts :meta {})
     :env (opts :env)
     :doc (opts :doc)
     :methods (tuple ;methods)
     :by-name (tabseq [m :in methods] (m :name) m)}))

# -- the registry --------------------------------------------------------

(def- registry @{})

(defn register!
  "Register a service value. Re-registering replaces — REPL-friendly,
  and the route table is rebuilt from the registry rather than cached."
  [svc]
  (put registry (svc :name) svc)
  svc)

(defn deregister!
  "Forget a service by name."
  [name]
  (put registry name nil)
  nil)

(defn services
  "Every registered service, by name."
  []
  (seq [n :in (sorted (keys registry))] (registry n)))

(defn lookup
  "A registered service by name, or nil."
  [name]
  (registry name))

(defn defservice-form
  ``The expansion `defservice` writes — a function rather than only a
  macro, because ./init exports the same macro under its own name, and
  a macro cannot be re-exported by calling it (the head of a form has
  to *be* a macro at the call site).``
  [name body]
  (unless (keyword? name)
    (errorf "defservice: the service name must be a keyword, got %q" name))
  (def head (first body))
  (def opts (if (dictionary? head) head {}))
  (def forms (if (dictionary? head) (slice body 1) body))
  (def bindings
    (seq [form :in forms]
      (unless (and (tuple? form) (= 'rpc (first form)) (<= 3 (length form) 4))
        (errorf "defservice: expected (rpc :Name handler [meta]), got %q" form))
      (def [_ mname handler meta] form)
      (def quoted (if (and (symbol? handler) (not (string/find "/" (string handler))))
                    ~',handler
                    handler))
      ~{:name ,mname :handler ,quoted :meta ,(or meta {})}))
  ~(,register! (,service ,name [,;bindings]
                         (,merge ,opts {:env (,router/env-ref (curenv))}))))

(defmacro defservice
  ``Declare and register an RPC service:

      (defservice :shop.orders/OrderService
        {:meta {:void.authz/policy :orders/may-call}}
        (rpc :GetOrder get-order)
        (rpc :PlaceOrder place-order {:void.db/txn true}))

  The leading dictionary is optional and carries the service-wide
  options (`:meta` is route metadata for every method — the group
  layer of ADR-0005's merge). Each `(rpc :Name handler [meta])` binds
  one method; a bare symbol is quoted for you, so redefining the
  handler in the REPL is live (ADR-0002), exactly as in `defroutes`.

  The service's *shape* comes from the registered descriptor of the
  same name — `(proto/defproto "…")` first, or
  `(proto/defservice-proto …)` for one declared in Janet.``
  [name & body]
  (defservice-form name body))
