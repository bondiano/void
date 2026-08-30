(import ../test-support/paths)
(import void/proto :as proto)
(import void/proto/descriptor :as pdesc)
(import void/grpc :as grpc)
(import void/grpc/service :as service)
(import void/grpc/mount :as mount)

(proto/load-file! "test/protos/orders.proto")
(proto/load-file! "test/protos/streaming.proto")

(defn- refused [f why]
  (def [ok err] (protect (f)))
  (assert (not ok) why)
  (if (string? err) err (string/format "%q" err)))

(defn get-order [msg _req] {:id (msg :id)})
(defn count-orders [_msg _req] {:count 3})
(defn place-order [msg _req] {:id "new" :total_cents (msg :total_cents)})
(defn explode [_msg _req] (error "boom"))
(defn slow [_msg _req] {:count 0})

# -- the shape comes from the .proto, the binding from here ---------------

(grpc/defservice :shop.orders/OrderService
  {:meta {:void.http/timeout 5}}
  (rpc :GetOrder get-order)
  (rpc :CountOrders count-orders)
  (rpc :PlaceOrder place-order {:name :orders/place})
  (rpc :Explode explode)
  (rpc :Slow slow))

(def svc (service/lookup :shop.orders/OrderService))
(assert svc "defservice registered the service")
(assert (= "shop.orders.OrderService" (svc :proto-name)))
(assert (= 5 (length (svc :methods))))

(def m (get-in svc [:by-name :GetOrder]))
(assert (= "/shop.orders.OrderService/GetOrder" (m :path))
        "the path is the one Connect specifies: the fully-qualified service, then the method")
(assert (= :shop.orders.OrderService/GetOrder (m :route-name))
        "and the route is named the way its clients name the method")
(assert (= :shop.orders/GetOrderRequest (m :input)) "the shape came from the .proto")
(assert (= :shop.orders/Order (m :output)))
(assert (m :idempotent) "including whether the method said it has side effects")
(assert (not (get-in svc [:by-name :PlaceOrder :idempotent])))

# -- what the declaration refuses -----------------------------------------

(assert (string/find "GetOrder"
                     (refused |(service/service :shop.orders/OrderService
                                                [{:name :CountOrders :handler count-orders}])
                              "a method the .proto declares and nothing answers"))
        "and the error names the method rather than waiting for a client to find it")

(def all-bindings
  [{:name :GetOrder :handler get-order} {:name :CountOrders :handler count-orders}
   {:name :PlaceOrder :handler place-order} {:name :Explode :handler explode}
   {:name :Slow :handler slow}])

(assert (string/find "Nonexistent"
                     (refused |(service/service :shop.orders/OrderService
                                                [;all-bindings
                                                 {:name :Nonexistent :handler count-orders}])
                              "a handler for a method the .proto does not declare")))

(assert (string/find "streaming"
                     (refused |(service/service :shop.feed/FeedService
                                                [{:name :Watch :handler count-orders}])
                              "a streaming method"))
        "and says so at the declaration, where the .proto can still be changed")

(refused |(service/service :shop.orders/Nope [])
         "a service with no descriptor is not a service")
(refused |(service/service :shop.orders/OrderService
                           [;(slice all-bindings 1) {:name :GetOrder :handler "not a function"}])
         "a handler that is not one")
(refused |(service/service :shop.orders/OrderService
                           [;all-bindings {:name :GetOrder :handler get-order}])
         "two bindings for one method")

# -- the projection into routes -------------------------------------------

(def rows (mount/describe))
(assert (= 5 (length rows)))
(def by-method (tabseq [r :in rows] (r :method) r))

(assert (= :shop.orders.OrderService/GetOrder (get-in by-method [:GetOrder :route])))
(assert (get-in by-method [:GetOrder :idempotent]))
(assert (= 5 (get-in by-method [:GetOrder :service-meta :void.http/timeout]))
        "the service's layer is the group's, and the router merges it — this package does not")
(assert (= :shop.orders/OrderService (get-in by-method [:GetOrder :meta :void.grpc/service])))
(assert (= :GetOrder (get-in by-method [:GetOrder :meta :void.grpc/method])))
(assert (= :orders/place (get-in by-method [:PlaceOrder :meta :name]))
        "and a method may name its own route")

(def routes (mount/routes))
(assert (routes :routes) "the projection is a route source like any other")
(def group (first (routes :children)))
(assert (= 5 (get-in group [:meta :void.http/timeout]))
        "so the service's metadata is on the group the methods sit in")
(assert (= 7 (length (group :children)))
        "five methods, and the two idempotent ones also answer GET — Connect's own form")

(def methods-seen (frequencies (map |($ :method) (group :children))))
(assert (= 5 (methods-seen :post)))
(assert (= 2 (methods-seen :get)))

# -- and it is a registry of values, so a second projection can read it ---

(assert (deep= (map |($ :path) rows) (map |($ :path) (grpc/methods)))
        "grpc/methods and the route projection read one registry, not two")

(service/deregister! :shop.orders/OrderService)
(assert (empty? (mount/describe)) "deregistering takes the routes with it")
(assert (empty? ((mount/routes) :children)))

(print "service ok")
