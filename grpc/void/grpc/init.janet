### void/grpc — Connect-RPC over the void/http kernel.
###
### gRPC compatibility without HTTP/2, which is the trade this package
### made and the reason this package is M rather than XL. A unary call
### is one POST with the encoded message as the body; the ecosystem
### reaches it through Connect clients directly, or through a
### transcoding proxy for peers that insist on gRPC's own framing.
###
###     (proto/defproto "protos/orders.proto")
###
###     (defn get-order [req-message req]
###       (or (orders/find (req-message :id))
###           (grpc/fail! :not_found (string "no order " (req-message :id)))))
###
###     (grpc/defservice :shop.orders/OrderService
###       {:meta {:void.authz/policy :orders/may-call}}
###       (rpc :GetOrder get-order)
###       (rpc :PlaceOrder place-order {:void.db/txn true}))
###
### **A method is a route, and that is the whole design.** ./mount
### projects every registered method into the one route table, so an
### RPC method carries the same metadata a page does and every policy
### that protects a route protects it: `:void.authz/policy` at
### :void.http/authorized, `:void.db/txn`, void/security's headers and limits,
### void/pressure's shedding, void/obs' RED metrics labelled by route
### name, `void routes` and `explain-route`. Nothing here
### re-implements any of it, and nothing else in void had to learn
### that RPC exists.
###
### **Nothing is declared twice.** The methods, their messages and
### whether they have side effects come from the `.proto` through
### void/proto's registry; `defservice` adds the handler and the route
### metadata, which are the two things a `.proto` cannot say. A method
### the file declares and nothing answers fails the *declaration* —
### an `unimplemented` a client discovers at runtime is a contract
### with a hole in it.
###
### **What lives where.** ./codes is the sixteen answers and their two
### mappings, ./connect is the protocol, ./service is the declaration
### and its registry, ./mount is the projection into routes, ./client
### is the other end.
###
### **What it does not do.** No streaming — Connect's streaming
### variants need a transport that keeps two directions open, and
### That waits for v2 and a decision of its own; a `.proto` that
### declares one is refused at `defservice`. No gRPC or gRPC-Web
### framing: those are length-prefixed envelopes and, for gRPC proper,
### HTTP/2 trailers — the ecosystem's answer to a Connect server is a
### transcoding proxy, and this ADR chose that on purpose. No
### compression (void has no compressor). No server reflection: it is
### a service defined in `descriptor.proto`, and void/proto carries
### neither.

(import spork/base64)
(import void/core/keys :as keys)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/proto :as proto)
(import void/proto/descriptor :as pdesc)
(import ./codes :as codes)
(import ./connect :as connect)
(import ./service :as service)
(import ./mount :as mount)
(import ./client :as client-module)

# -- what a handler uses -------------------------------------------------

(defn fail!
  {:params [GrpcCode :string GrpcFailureOptions?]
   :ret :never
   :throws [:string GrpcFailure]}
  ``Raise an RPC failure — the code, and a message for a person:

      (grpc/fail! :not_found "no order A-1")
      (grpc/fail! :invalid_argument "quantity must be positive"
                  {:details [{:type "shop.orders.BadField" :value {:field "quantity"}}]})``
  [code message &opt opts]
  (codes/fail! code message opts))

(defn error-value
  {:params [GrpcCode :string GrpcFailureOptions?]
   :ret GrpcFailure
   :throws [:string]}
  "Build an RPC failure without raising it."
  [code message &opt opts]
  (codes/error-value code message opts))

(defn respond
  {:params [:any (or {:headers (or @{:string :string} :nil) :trailers (or @{:string :string} :nil) & r} :nil)]
   :ret @{:void.grpc/response :boolean :message :any :headers @{:string :string}
         :trailers @{:string :string}}}
  "A response message plus headers or trailers — see connect/respond."
  [message &opt opts]
  (connect/respond message opts))

(defn current-call
  {:params []
   :ret (or :nil {:service :keyword :method :keyword :descriptor :any :codec :keyword :req :any})}
  "The call this fiber is answering: {:service :method :descriptor
  :codec :req}, or nil."
  []
  (mount/current-call))

(defn services
  {:params []
   :ret @[{:name :keyword :descriptor :any :proto-name :string :path :string
          :meta :any :env :any :doc (or :string :nil) :methods [:any] :by-name @{:keyword :any}}]}
  "Every registered service value."
  []
  (service/services))

(defn methods
  {:params []
   :ret @[{:service :keyword :method :keyword :path :string :route :keyword
          :get-route (or :keyword :nil) :input :any :output :any :idempotent :boolean
          :meta @{:keyword :any} :service-meta :any}]}
  "Every mounted method, as data — what `void grpc services` prints."
  []
  (mount/describe))

# -- the other end -------------------------------------------------------

(defn client
  {:params [:any
            (or {:encoding (or :keyword :nil) :headers (or @{:string :string} :nil)
                :timeout (or :number :nil) & r}
                :nil)]
   :ret @{:url :string :encoding :keyword :headers @{:string :string} :timeout (or :number :nil)}
   :throws [:string]}
  ``A Connect client against a base URL — see client/client:

      (def orders (grpc/client "http://127.0.0.1:8080"))``
  [base-url &opt opts]
  (client-module/client base-url opts))

(defn call
  {:params [@{:url :string :encoding :keyword :headers @{:string :string}
              :timeout (or :number :nil)}
            :keyword :keyword :any
            (or {:headers (or @{:string :string} :nil) :timeout (or :number :nil)
                :get (or :boolean :nil) :full (or :boolean :nil) & r}
                :nil)]
   :ret (or :any @{:message :any :headers @{:string :any} :trailers @{:string :any}})
   :throws [GrpcFailure]}
  ``One unary call through a client. Returns the response message and
  raises the RPC failure when the server sent one — see client/call
  for the options (`:headers`, `:timeout`, `:get`, `:full`):

      (grpc/call orders :shop.orders/OrderService :GetOrder {:id "A-1"})``
  [c svc-name method-name message &opt opts]
  (client-module/call c svc-name method-name message opts))

(def trailers
  "See client/trailers — a call's trailing metadata."
  client-module/trailers)

(defmacro defservice
  {:params [:any :any] :ret :any}
  ``Declare and register an RPC service — the macro service/defservice
  documents, exported here so an application imports one module:

      (grpc/defservice :shop.orders/OrderService
        {:meta {:void.authz/policy :orders/may-call}}
        (rpc :GetOrder get-order)
        (rpc :PlaceOrder place-order {:void.db/txn true}))``
  [name & body]
  (service/defservice-form name body))

# -- codecs --------------------------------------------------------------

(plugin/defextension-point :void.grpc/codec
  :doc "Connect codecs: {:name :void.grpc/proto :content-type \"application/proto\" :aliases [...]? :encoding \"proto\" :encode (fn [message value] bytes) :decode (fn [message bytes] value)}. `:encoding` is the name Connect's GET form uses in ?encoding=; the first codec whose content type matches a request serves it. void/grpc ships the two the protocol defines, and the point exists because a fleet that speaks a third one internally should not need a second server"
  :schema {:name :keyword
           :content-type :string
           :encoding :string
           :encode :function
           :decode :function
           :aliases [:optional [:vector :string]]
           :encoding-aliases [:optional [:vector :string]]
           :doc [:optional :string]}
  :key :name :what "Connect codec"
  # the first codec whose content type matches serves the request, so
  # the resolution keeps contribution order rather than name order
  :reduce identity)

(var settings
  "The [:grpc] slice, read at :before-start."
  nil)

(defn- json-options
  {:params []
   :ret {:emit-defaults (or :boolean :nil) :proto-names (or :boolean :nil)
        :ignore-unknown (or :boolean :nil) :enums-as-numbers (or :boolean :nil) & r}}
  "The [:grpc :json] slice — proto3 JSON mapping options for the JSON codec."
  []
  (get settings :json {}))

(plugin/contribute! :void.grpc/codec
  {:name :void.grpc/proto
   :content-type "application/proto"
   :aliases ["application/protobuf" "application/x-protobuf"]
   :encoding "proto"
   :encoding-aliases ["protobuf"]
   :doc "protobuf's binary encoding — what a generated client uses unless told otherwise"
   :encode (fn encode-proto [message value] (string (proto/encode message value)))
   :decode (fn decode-proto [message bytes] (proto/decode message bytes))})

(plugin/contribute! :void.grpc/codec
  {:name :void.grpc/json
   :content-type "application/json"
   :encoding "json"
   :doc "the proto3 JSON mapping (void/proto/json) — the encoding a browser and a curl can read"
   :encode (fn encode-json [message value]
             (proto/encode-json message value (json-options)))
   :decode (fn decode-json [message bytes]
             # from the raw bytes: the proto3 JSON mapping is defined
             # over the *names* a peer sent, and an RPC route is marked
             # :void.http/body :raw (mount/method-meta) so no other
             # codec — void/rest's, with its keyword keys — has run
             (proto/decode-json message (string bytes) (json-options)))})

# -- error details -------------------------------------------------------

(defn- encode-detail
  {:params [:any] :ret @{:string :any}}
  ``One `details` entry of a Connect error. `{:type "shop.orders.BadField"
  :value <message>}` encodes the value with the descriptor its type
  names and carries it as base64, which is what a generated client
  decodes back into a typed detail. A value that is already bytes is
  passed through.``
  [detail]
  (def type (string (get detail :type (get detail "type" ""))))
  (def value (get detail :value (get detail "value")))
  (def encoded
    (cond
      (bytes? value) (base64/encode (string value))
      (nil? value) ""
      (base64/encode (string (proto/encode (pdesc/name-of type) value)))))
  (def out @{"type" type "value" encoded})
  (when-let [debug (get detail :debug)] (put out "debug" debug))
  out)

# -- route metadata ------------------------------------------------------

# the route carries :void.grpc/method alone: the service is already in
# the route's name (:pkg.Service/Method), and nothing ever read a
# second key for it (ADR-0046)
(plugin/contribute! :void.http/route-meta-key
  {:key :void.grpc/method
   :schema :keyword
   :doc "The RPC method this route serves — set by void/grpc's projection; its presence is what the Connect error renderer keys on"
   :merge :replace})

# -- errors raised by the rest of the stack ------------------------------

(plugin/contribute! :void.http/error-renderer
  {:name :void.grpc/error
   # a protocol renderer, ahead of every general one (void/rest's
   # problem+json among them): on an RPC route the client is a
   # generated stub that reads Connect errors and nothing else, and an
   # RFC 7807 body would reach it as an unparseable 403
   :before :void.http.error/protocol
   :fn (fn render-connect [err req _ctx]
         (when (get (keys/route-meta req) :void.grpc/method)
           (mount/error-response err)))})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:grpc] config slice."
  {:mount [:optional :boolean]
   :require-protocol-version [:optional :boolean]
   :describe-errors [:optional :boolean]
   :json [:optional {:emit-defaults [:optional :boolean]
                     :proto-names [:optional :boolean]
                     :ignore-unknown [:optional :boolean]
                     :enums-as-numbers [:optional :boolean]}]})

(def defaults
  {:mount true
   # every Connect client sends Connect-Protocol-Version; requiring it
   # is a CSRF-shaped defence, and an `application/json` POST is not a
   # CORS-simple request in the first place, so it is off unless an
   # application wants the second lock
   :require-protocol-version false
   :json {}})

(defn build-settings
  {:params [{:config :any :profile :keyword & r}]
   :ret @{:mount :boolean :require-protocol-version :boolean :json :any
          :describe-errors :boolean & r}}
  "The [:grpc] slice over the defaults. `:describe-errors` defaults to
  on outside :prod, because an unhandled error's text is a stack of
  somebody's internals and a client is not who should read it."
  [boot]
  (def cfg (merge defaults (or (get-in boot [:config :values :grpc]) {})))
  (merge cfg
         {:describe-errors (if (nil? (cfg :describe-errors))
                             (not= :prod (boot :profile))
                             (cfg :describe-errors))}))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :before :void.core/configured
   :name :grpc/capture-config
   :doc "Read the [:grpc] slice and resolve the codecs before the route table is built"
   :fn (fn capture [boot]
         (set settings (build-settings boot))
         (set mount/settings-ref settings)
         (set mount/detail-encoder encode-detail)
         (set mount/codecs-ref (get-in boot [:extensions :void.grpc/codec :resolved] [])))})

# -- the route source ----------------------------------------------------

(defn- own-routes
  {:params [:any] :ret :any}
  "This plugin's own route source: every registered method, or an
  empty route source when [:grpc :mount] is off."
  [_boot]
  (if (get settings :mount true)
    (mount/routes)
    (router/routes {})))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :grpc/services
   :read-only? true
   :doc "List the RPC methods this application serves"
   :args []
   :fn (fn cli-services []
         (def rows (mount/describe))
         (if (empty? rows)
           (print "no RPC services are registered")
           (each r rows
             (printf "%-6s %-52s %s -> %s"
                     (if (r :idempotent) "GET" "POST")
                     (r :path)
                     (pdesc/proto-name (r :input))
                     (pdesc/proto-name (r :output))))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/grpc
  :doc "Connect-RPC over the void/http kernel: unary methods on HTTP/1.1, protobuf and proto3-JSON codecs, `defservice` bound to a service a .proto already declared, and every method projected into the one route table — so route metadata, authz, transactions, obs and pressure work on an RPC method exactly as on a page."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1" :void/proto ">=0.0.1"}
  :config-key :grpc
  :config-schema Config
  :config-defaults defaults
  :contributes
  {:void.http/route-source
   [{:name :void/grpc
     # a function, not a value: the services this projects are
     # declared by the application's own modules, long after this
     # manifest froze (see :void.http/route-source in void/http)
     :routes own-routes}]})
