(import ../test-support/paths)
(import void/test)
(import void/core/plugin :as plugin)
(import void/proto :as proto)
(import void/grpc :as grpc)
(import void/grpc/codes :as codes)
(require "void/http/init")

### The client, against a real socket. void/http/client is what it
### speaks through, so this is also the assertion that the two halves
### of the design — a Connect server on void/http and a Connect client on
### void/http/client — agree about the protocol they were written from.

(proto/load-file! "test/protos/orders.proto")

(def orders @{"A-1" {:id "A-1" :total_cents 990 :status :STATUS_PLACED}})

(defn get-order [msg _req]
  (or (orders (msg :id))
      (grpc/fail! :not_found (string "no order " (msg :id)))))
(defn count-orders [_msg _req] {:count (length orders)})
(defn place-order [msg _req]
  (def order {:id "A-2" :total_cents (msg :total_cents) :status :STATUS_PLACED})
  (put orders "A-2" order)
  order)
(defn explode [_msg _req] (grpc/fail! :resource_exhausted "too many orders"))
(defn slow [_msg _req] (ev/sleep 1) {:count 0})

(grpc/defservice :shop.orders/OrderService
  (rpc :GetOrder get-order)
  (rpc :CountOrders count-orders)
  (rpc :PlaceOrder place-order)
  (rpc :Explode explode)
  (rpc :Slow slow))

(def boot
  (test/start! {:plugins [:void/http :void/proto :void/grpc]
                :config {:env @{}
                         :cli {:log {:level :error}
                               :http {:port 0 :strict-meta true :access-log false}}}}))

(def port (get-in boot [:system :instances :http/server :server :port]))
(assert (pos? port) "the server bound an ephemeral port")

(defer (test/stop! boot 3)
  (def base (string "http://127.0.0.1:" port))

  (each encoding [:proto :json]
    (def c (grpc/client base {:encoding encoding}))

    (def order (grpc/call c :shop.orders/OrderService :GetOrder {:id "A-1"}))
    (assert (= "A-1" (order :id)) (string/format "a call in %q comes back decoded" encoding))
    (assert (= 990 (order :total_cents)))
    (assert (= :STATUS_PLACED (order :status))
            "and an enum is a name at both ends, whichever codec carried it")

    (def [ok failure] (protect (grpc/call c :shop.orders/OrderService :GetOrder {:id "A-9"})))
    (assert (not ok) "a failure is raised, the way every generated client raises one")
    (assert (= :not_found (failure codes/key)))
    (assert (= "no order A-9" (failure :message)))
    (assert (= 404 (failure :http/status)))

    (def [_ exhausted] (protect (grpc/call c :shop.orders/OrderService :Explode {})))
    (assert (= :resource_exhausted (exhausted codes/key))
            "and the code survives the trip rather than collapsing into \"unknown\""))

  # -- the GET form, and who is allowed to ask for it ---------------------

  (def c (grpc/client base))
  (assert (= 1 ((grpc/call c :shop.orders/OrderService :CountOrders {} {:get true}) :count))
          "an idempotent method can be called with GET, message and all")
  (def [ok err] (protect (grpc/call c :shop.orders/OrderService :PlaceOrder
                                    {:total_cents 5} {:get true})))
  (assert (not ok))
  (assert (string/find "NO_SIDE_EFFECTS" (if (string? err) err (string/format "%q" err)))
          "and one that did not declare itself safe is refused here, not at the server")

  # -- a method that does not exist is caught before a socket is opened ---

  (assert (not (first (protect (grpc/call c :shop.orders/OrderService :Nope {})))))
  (assert (not (first (protect (grpc/call c :shop.orders/Nothing :GetOrder {})))))

  # -- the response metadata, for a caller that wants it -------------------

  (def full (grpc/call c :shop.orders/OrderService :GetOrder {:id "A-1"} {:full true}))
  (assert (= "A-1" (get-in full [:message :id])))
  (assert (string/has-prefix? "application/proto" (get-in full [:headers "content-type"])))
  (assert (deep= @{} (full :trailers)) "this method sends none")

  # -- headers ride along ---------------------------------------------------

  (def with-headers (grpc/client base {:headers {"x-tenant" "acme"}}))
  (assert (= "A-1" ((grpc/call with-headers :shop.orders/OrderService
                               :GetOrder {:id "A-1"}) :id))
          "a client's headers are sent with every call")

  # -- the deadline is the client's, and the server enforces it ------------

  (def [ok timeout] (protect (grpc/call c :shop.orders/OrderService :Slow {} {:timeout 0.15})))
  (assert (not ok))
  (assert (= :deadline_exceeded (timeout codes/key))
          "Connect-Timeout-Ms is a deadline both ends agree on")

  # -- and a write really wrote --------------------------------------------

  (def placed (grpc/call c :shop.orders/OrderService :PlaceOrder {:total_cents 1500}))
  (assert (= "A-2" (placed :id)))
  (assert (= 1500 (placed :total_cents)))
  (assert (= 2 ((grpc/call c :shop.orders/OrderService :CountOrders {}) :count))))

(print "client ok")
