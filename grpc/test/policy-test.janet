(import ../test-support/paths)
(import spork/json)
(import void/test)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/proto :as proto)
(import void/grpc :as grpc)
(import void/authz :as authz)
(require "void/http/init")
(require "void/authz/http")
(require "void/rest/init")

### The promise, checked: one policy stack (auth/authz/obs/validation)
### over HTTP and over RPC. An RPC method carries route metadata,
### so `:void.authz/policy` is *the same key* enforced by the same
### middleware in the same phase as on a page — and this file is the
### assertion that nothing in void/grpc had to know that.

(proto/load-file! "test/protos/orders.proto")

(authz/defpolicy :orders/may-read
  "Anybody the request could name may read an order."
  [ctx]
  (if (authz/attr ctx :subject/subject) true "no identity"))

(authz/defpolicy :orders/may-place
  "Only the buyer places orders."
  [ctx]
  (if (= "user:buyer" (authz/attr ctx :subject/subject)) true "not the buyer"))

(defn get-order [msg _req] {:id (msg :id)})
(defn count-orders [_msg _req] {:count 1})
(defn place-order [msg _req] {:id "A-2" :total_cents (msg :total_cents)})
(defn explode [_msg _req] {:count 0})
(defn slow [_msg _req] {:count 0})

(grpc/defservice :shop.orders/OrderService
  {:meta {:void.authz/policy :orders/may-read}}
  (rpc :GetOrder get-order)
  (rpc :CountOrders count-orders)
  (rpc :PlaceOrder place-order {:void.authz/policy :orders/may-place})
  (rpc :Explode explode)
  (rpc :Slow slow))

# an ordinary route in the same application, so the two error
# renderers have to coexist rather than take turns
(defn page [_req] (ring/text 200 "a page"))
(defn boom [_req] (error {:http/status 403 :message "not yours"}))

(def app-routes
  (router/routes {:void.authz/policy :public}
    (router/GET "/page" 'page {:name :page})
    (router/GET "/boom" 'boom {:name :boom})))

(def app
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/grpc ">=0.0.1"}
    :contributes {:void.http/route-source
                  [{:name :test/app :routes app-routes
                    :env (router/env-ref (curenv))}]}))

(def path "/shop.orders.OrderService/")

(defn- rpc [c method message &opt input identity]
  (with-dyns [authz/identity-dyn identity]
    (test/inject c {:method :post
                    :uri (string path method)
                    :headers @{"content-type" "application/json"
                               "connect-protocol-version" "1"}
                    :body (proto/encode-json (or input :shop.orders/GetOrderRequest) message)})))

(def boot
  (test/start! {:plugins [:void/http :void/rest :void/proto :void/grpc
                          :void/authz :void/authz-http app]
                # the registry is where the built-in :public policy is
                # registered (at :start, so a plugin's policy and an
                # application's are the same kind of thing) — a suite
                # that only started the kernel would not have it
                :only [:http/kernel :authz/registry]
                :config {:env @{}
                             :cli {:log {:level :error}
                                   :http {:strict-meta true :access-log false}
                                   :authz {:default :deny :log :none}}}}))
(def c (test/client boot))

(defer (test/stop! boot)

  # -- [:authz :default :deny] reaches RPC methods too -------------------
  #
  # The boot above succeeded, and under :deny a route with no policy
  # fails the boot — so every method got one, from the service's layer
  # or its own. That is the authz gate closing over routes this
  # package generated, with no cooperation from this package.

  (def denied (rpc c "GetOrder" {:id "A-1"}))
  (assert (= 403 (denied :status)))
  (def body (json/decode (string (denied :body))))
  (assert (= "permission_denied" (body "code"))
          "a policy that says no reaches an RPC client as the code it means")
  (assert (not (string/find "no identity" (string (denied :body))))
          "and the *reason* stays in the log, exactly as it does for a page")

  (def allowed (rpc c "GetOrder" {:id "A-1"} nil {:subject "user:someone"}))
  (assert (= 200 (allowed :status)))
  (assert (= "A-1" ((json/decode (string (allowed :body))) "id")))

  # the method's own policy is stricter than the service's, and the
  # router merged them — this package did not
  (def wrong-subject (rpc c "PlaceOrder" {:total_cents 5}
                          :shop.orders/PlaceOrderRequest {:subject "user:someone"}))
  (assert (= 403 (wrong-subject :status)))
  (def buyer (rpc c "PlaceOrder" {:total_cents 5}
                  :shop.orders/PlaceOrderRequest {:subject "user:buyer"}))
  (assert (= 200 (buyer :status)))
  (assert (= "5" ((json/decode (string (buyer :body))) "totalCents")))

  # -- and the two error renderers stay out of each other's way ----------

  (def page-403 (test/inject c {:uri "/boom" :headers @{"accept" "application/json"}}))
  (assert (= 403 (page-403 :status)))
  (assert (string/has-prefix? "application/problem+json"
                              (get-in page-403 [:headers "content-type"]))
          "an ordinary route still answers RFC 7807, because void/rest is in the composition")
  (assert (not (get (json/decode (string (page-403 :body))) "code"))
          "and its body is a problem document, not a Connect error")

  (assert (= 200 ((test/inject c {:uri "/page"}) :status))))

# -- a route with no policy still fails the boot -------------------------

(grpc/defservice :shop.orders/OrderService
  (rpc :GetOrder get-order)
  (rpc :CountOrders count-orders)
  (rpc :PlaceOrder place-order)
  (rpc :Explode explode)
  (rpc :Slow slow))

(def [ok err]
  (protect (test/start! {:plugins [:void/http :void/proto :void/grpc
                                   :void/authz :void/authz-http]
                         :only [:http/kernel]
                         :config {:env @{}
                                  :cli {:log {:level :error}
                                        :http {:strict-meta true :access-log false}
                                        :authz {:default :deny :log :none}}}})))
(assert (not ok) "under [:authz :default :deny] an unguarded RPC method fails the boot")
(assert (string/find "OrderService" (if (string? err) err (string/format "%q" err)))
        "and the failure names the method, which is a route like any other")

(print "policy ok")
