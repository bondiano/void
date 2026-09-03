(import ../test-support/paths)
(import spork/json)
(import spork/base64)
(import void/test)
(import void/core/plugin :as plugin)
(import void/proto :as proto)
(import void/grpc :as grpc)
(require "void/http/init")

### The protocol, end to end, through the whole kernel: the requests below
### take the same path a socket's would — routing, the phase chain, the
### error renderers — because that is the claim this package makes about
### Connect on void, and a test that called the handler directly would not
### check it.

(proto/load-file! "test/protos/orders.proto")

(def orders @{"A-1" {:id "A-1" :total_cents 990 :status :STATUS_PLACED
                     :labels ["web"] :placed_at {:seconds 1000000}}})

(defn get-order [msg _req]
  (or (orders (msg :id))
      (grpc/fail! :not_found (string "no order " (msg :id)))))

(defn count-orders [_msg _req]
  # the call this fiber is answering, for the layer under a handler
  # that wants to know which method it is inside without being passed it
  (def call (grpc/current-call))
  (assert (= :shop.orders/OrderService (call :service)))
  (assert (= :CountOrders (call :method)))
  (assert (call :req) "and the request that brought it")
  (grpc/respond {:count (length orders)} {:trailers {"x-source" "memory"}}))

(defn place-order [msg _req]
  (when (<= (msg :total_cents) 0)
    (grpc/fail! :invalid_argument "an order costs something"
                {:details [{:type "shop.orders.BadField"
                            :value {:field "total_cents" :reason "must be positive"}}]}))
  {:id "A-2" :total_cents (msg :total_cents) :status :STATUS_PLACED})

(defn explode [_msg _req] (error "a secret from the innards"))

(defn slow [_msg _req] (ev/sleep 0.5) {:count 0})

(grpc/defservice :shop.orders/OrderService
  (rpc :GetOrder get-order)
  (rpc :CountOrders count-orders)
  (rpc :PlaceOrder place-order)
  (rpc :Explode explode)
  (rpc :Slow slow))

(def app
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/grpc ">=0.0.1"}))

(def path "/shop.orders.OrderService/")

(defn- call [c method body &opt opts]
  (default opts {})
  (test/inject c (merge {:method :post
                         :uri (string path method)
                         :headers @{"content-type" (get opts :content-type "application/proto")
                                    "connect-protocol-version" "1"}
                         :body body}
                        (get opts :request {}))))

(defn- proto-call [c method message &opt opts]
  (default opts {})
  (call c method (string (proto/encode (get opts :input :shop.orders/GetOrderRequest) message))
        opts))

(defn- json-call [c method message &opt opts]
  (default opts {})
  (call c method (proto/encode-json (get opts :input :shop.orders/GetOrderRequest) message)
        (merge {:content-type "application/json"} opts)))

(defn- error-of [resp] (json/decode (string (resp :body))))

(test/with-http [c {:plugins [:void/http :void/proto :void/grpc app]
                    :config {:env @{}
                             :cli {:log {:level :error}
                                   :http {:strict-meta true :access-log false}}}}]

  # -- a call is one POST, and the body is the message -------------------

  (def resp (proto-call c "GetOrder" {:id "A-1"}))
  (assert (= 200 (resp :status)))
  (assert (= "application/proto" (get-in resp [:headers "content-type"])))
  (def order (proto/decode :shop.orders/Order (resp :body)))
  (assert (= "A-1" (order :id)))
  (assert (= 990 (order :total_cents)))
  (assert (= :STATUS_PLACED (order :status)))
  (assert (= 1000000 (get-in order [:placed_at :seconds])))

  # the same call in the other codec, and the same answer
  (def jresp (json-call c "GetOrder" {:id "A-1"}))
  (assert (= 200 (jresp :status)))
  (assert (string/has-prefix? "application/json" (get-in jresp [:headers "content-type"])))
  (def jorder (json/decode (string (jresp :body))))
  (assert (= "A-1" (jorder "id")))
  (assert (= "990" (jorder "totalCents")) "and it obeys the proto3 JSON mapping, 64 bits and all")
  (assert (= "1970-01-12T13:46:40Z" (jorder "placedAt")))

  # -- a failure is a status and a body that names its code --------------

  (def missing (proto-call c "GetOrder" {:id "A-9"}))
  (assert (= 404 (missing :status)) "not_found is a 404, which is the protocol's own table")
  (assert (string/has-prefix? "application/json" (get-in missing [:headers "content-type"]))
          "and an error is JSON whatever the call's codec was — an unreadable error is not one")
  (assert (= "not_found" ((error-of missing) "code")))
  (assert (= "no order A-9" ((error-of missing) "message")))

  (def bad (proto-call c "PlaceOrder" {:total_cents 0} {:input :shop.orders/PlaceOrderRequest}))
  (assert (= 400 (bad :status)))
  (def body (error-of bad))
  (assert (= "invalid_argument" (body "code")))
  (def detail (first (body "details")))
  (assert (= "shop.orders.BadField" (detail "type")))
  (assert (= "total_cents"
             ((proto/decode :shop.orders/BadField (base64/decode (detail "value"))) :field))
          "a detail is the encoded message, base64 — which is what a generated client decodes")

  # -- what a handler must not leak --------------------------------------

  (def boom (proto-call c "Explode" {} {:input :shop.orders/CountRequest}))
  (assert (= 500 (boom :status)))
  (assert (= "internal" ((error-of boom) "code")))
  (assert (string/find "secret" ((error-of boom) "message"))
          "in :test the message is the error, because a developer is reading it")

  # -- the GET form, for a method whose .proto said it is safe -----------

  (def message (base64/encode (string (proto/encode :shop.orders/GetOrderRequest {:id "A-1"}))))
  (def urlsafe (string/replace-all "=" "" (string/replace-all "/" "_"
                                                              (string/replace-all "+" "-" message))))
  (def got (test/inject c {:method :get
                           :uri (string path "GetOrder"
                                        "?connect=v1&encoding=proto&base64=1&message=" urlsafe)}))
  (assert (= 200 (got :status)) "an idempotent method answers GET, so a cache has something to do")
  (assert (= "A-1" ((proto/decode :shop.orders/Order (got :body)) :id)))

  (def got-json (test/inject c {:method :get
                                :uri (string path "CountOrders"
                                             "?connect=v1&encoding=json&message=%7B%7D")}))
  (assert (= 200 (got-json :status)) "and the JSON form needs no base64 at all")
  (assert (= 1 ((json/decode (string (got-json :body))) "count")))

  (assert (= 405 ((test/inject c {:method :get :uri (string path "PlaceOrder")}) :status))
          "a method with side effects has no GET route — the .proto decided that")

  (def old-version (test/inject c {:method :get
                                   :uri (string path "CountOrders"
                                                "?connect=v2&encoding=json&message=%7B%7D")}))
  (assert (= 400 (old-version :status))
          "and ?connect= is checked the way the header is: wrong is refused, absent is not")

  (def no-ct (test/inject c {:method :post :uri (string path "GetOrder") :body "x"}))
  (assert (= 415 (no-ct :status))
          "a POST with no Content-Type names no codec, and that is the same refusal")

  # -- trailers ----------------------------------------------------------

  (def counted (proto-call c "CountOrders" {} {:input :shop.orders/CountRequest}))
  (assert (= "memory" (get-in counted [:headers "trailer-x-source"]))
          "a unary call's trailers ride as Trailer-prefixed headers, which is Connect's own rule")

  # -- what the transport refuses ----------------------------------------

  (def wrong-codec (call c "GetOrder" "" {:content-type "application/xml"}))
  (assert (= 415 (wrong-codec :status))
          "the protocol calls an unrecognised codec an unsupported media type")
  (assert (= "unimplemented" ((error-of wrong-codec) "code")))
  (assert (string/find "application/proto" ((error-of wrong-codec) "message"))
          "and the refusal lists the codecs this server does have")

  (def gzipped (call c "GetOrder" "" {:request {:headers @{"content-type" "application/proto"
                                                           "content-encoding" "gzip"}}}))
  (assert (= 415 (gzipped :status)))
  (assert (= "unimplemented" ((error-of gzipped) "code"))
          "and the code in the body still says which of the sixteen it was")
  (assert (= "identity" (get-in gzipped [:headers "accept-encoding"]))
          "void has no compressor, and says which encoding it does read")

  (def wrong-version (call c "GetOrder" ""
                           {:request {:headers @{"content-type" "application/proto"
                                                 "connect-protocol-version" "2"}}}))
  (assert (= 400 (wrong-version :status)))
  (assert (string/find "1" ((error-of wrong-version) "message")))

  (def no-version (call c "GetOrder"
                        (string (proto/encode :shop.orders/GetOrderRequest {:id "A-1"}))
                        {:request {:headers @{"content-type" "application/proto"}}}))
  (assert (= 200 (no-version :status))
          "a missing version header is accepted by default — see [:grpc :require-protocol-version]")

  (def garbage (call c "GetOrder" "\xff\xff\xff\xff"))
  (assert (= 400 (garbage :status)))
  (assert (= "invalid_argument" ((error-of garbage) "code"))
          "a body the codec cannot read is the caller's problem, and says so")

  (assert (= 404 ((test/inject c {:method :post :uri (string path "Nonexistent")}) :status))
          "a method nobody declared has no route, and a 404 is what that is")

  # -- the client's deadline ---------------------------------------------

  (def timed-out (call c "Slow" (string (proto/encode :shop.orders/CountRequest {}))
                       {:request {:headers @{"content-type" "application/proto"
                                             "connect-protocol-version" "1"
                                             "connect-timeout-ms" "50"}}}))
  (assert (= 504 (timed-out :status)))
  (assert (= "deadline_exceeded" ((error-of timed-out) "code"))
          "the client's Connect-Timeout-Ms is enforced here, not only there")

  (def bad-deadline (call c "GetOrder" ""
                          {:request {:headers @{"content-type" "application/proto"
                                                "connect-timeout-ms" "soon"}}}))
  (assert (= 400 (bad-deadline :status))
          "and a deadline nobody can read is refused rather than dropped"))

(print "connect ok")
