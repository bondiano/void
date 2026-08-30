(import ../test-support/paths)
(import void/proto :as proto)
(import void/proto/descriptor :as desc)
(import void/core/schema :as schema)

### `defproto` is the codegen macro SPEC §5.7 asks for, and what it
### generates is data: the file is parsed while *this module compiles*
### and the descriptors are baked into it, so a running application
### never reads a `.proto` (§8.5 rule 3). The path is relative to this
### file, which is why it is not the one test/parse-test.janet passes
### to `parse/load`.

(proto/defproto "protos/orders.proto")

(assert (desc/lookup :shop.orders/Order) "the file's messages are registered at load")
(assert (desc/lookup :shop.catalog/Product) "and so are the ones it imports")
(assert (desc/lookup :google.protobuf/Timestamp))
(assert (desc/service! :shop.orders/OrderService) "services too")
(assert (schema/lookup :shop.orders/Order) "with the schema layer watching, as always")

(def payload (proto/encode :shop.orders/Order {:id "A-1" :total_cents 990}))
(assert (= "A-1" ((proto/decode :shop.orders/Order payload) :id))
        "and the descriptors that were baked in encode exactly like the parsed ones")

# -- a service declared in Janet rather than in a file --------------------

(proto/defmessage :hand/Ping {:nonce [1 :int64]})
(proto/defmessage :hand/Pong {:nonce [1 :int64]})
(proto/defservice-proto :hand/PingService
  [{:name :Ping :input :hand/Ping :output :hand/Pong :idempotent true}])

(def svc (desc/service! :hand/PingService))
(assert (= "hand.PingService" (svc :proto-name)))
(assert (= :hand/Pong (get-in svc [:by-name :Ping :output])))
(assert (get-in svc [:by-name :Ping :idempotent])
        "a service declared here says the same things a .proto would")

(print "defproto ok")
