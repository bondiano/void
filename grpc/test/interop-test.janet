(import ../test-support/paths)
(import spork/json)
(import void/test)
(import void/proto :as proto)
(import void/grpc :as grpc)
(require "void/http/init")

### Wave 4's second exit criterion: a Connect-RPC service is called by
### a grpcurl/buf client. This file is that criterion, run rather
### than asserted — `buf curl` is the Buf toolchain's own Connect
### client, it reads the same `.proto` this server was built from, and
### it knows nothing about void.
###
### It is a gate where `buf` is installed and a loud skip where it is
### not, the way void/db-postgres' integration suite is a gate only
### where VOID_TEST_PG names a server. Adding buf to the CI image would
### make it one everywhere; until then the claim is checked on the
### machine of whoever changes the protocol, which is where it matters
### most.

(defn- which [program]
  (def p (os/spawn ["/bin/sh" "-c" (string "command -v " program)] :px {:out :pipe :err :pipe}))
  (def out (ev/read (p :out) 4096))
  (ev/read (p :err) 4096)
  (if (zero? (os/proc-wait p)) (string/trim (string out)) nil))

(def buf (which "buf"))

# the service is declared at the top level whether or not buf is here:
# `defservice` resolves its handlers against this module's environment
# (late binding), and a handler defined inside an `if` is a
# local rather than a binding anything can find

(proto/load-file! "test/protos/orders.proto")

(def orders @{"A-1" {:id "A-1" :total_cents 990 :status :STATUS_PLACED :labels ["web"]}})

(defn get-order [msg _req]
  (or (orders (msg :id))
      (grpc/fail! :not_found (string "no order " (msg :id)))))
(defn count-orders [_msg _req] {:count (length orders)})
(defn place-order [msg _req] {:id "A-2" :total_cents (msg :total_cents)})
(defn explode [_msg _req] (grpc/fail! :permission_denied "not yours"))
(defn slow [_msg _req] {:count 0})

(grpc/defservice :shop.orders/OrderService
  (rpc :GetOrder get-order)
  (rpc :CountOrders count-orders)
  (rpc :PlaceOrder place-order)
  (rpc :Explode explode)
  (rpc :Slow slow))

(defn- run-interop []
  (def boot
    (test/start! {:plugins [:void/http :void/proto :void/grpc]
                  :config {:env @{}
                           :cli {:log {:level :error}
                                 :http {:port 0 :access-log false}}}}))
  (def port (get-in boot [:system :instances :http/server :server :port]))

  (defn curl [method body]
    (def p (os/spawn [buf "curl" "--protocol" "connect"
                      "--schema" "test/protos"
                      "-d" body
                      (string "http://127.0.0.1:" port "/shop.orders.OrderService/" method)]
                     :px {:out :pipe :err :pipe}))
    (def out (ev/read (p :out) 65536))
    (def err (ev/read (p :err) 65536))
    # buf curl exits non-zero when the *call* failed, which is half of
    # what this file is checking — so the exit code is data, not a
    # reason to stop
    (protect (os/proc-wait p))
    [(string (or out "")) (string (or err ""))])

  (defer (test/stop! boot 3)
    (def [out err] (curl "GetOrder" `{"id":"A-1"}`))
    (assert (not (empty? out))
            (string "buf curl said nothing; its stderr was: " err))
    (def order (json/decode out))
    (assert (= "A-1" (order "id"))
            "buf's own Connect client reads this server's answer")
    (assert (= "990" (order "totalCents"))
            "and agrees about the proto3 JSON mapping of a 64-bit integer")
    (assert (= "STATUS_PLACED" (order "status")) "and about an enum")

    # buf prints a failed call's Connect error on stderr, which is
    # where a command-line client puts what went wrong
    (defn answer [[out err]] (json/decode (if (empty? out) err out)))

    (def failure (answer (curl "GetOrder" `{"id":"A-9"}`)))
    (assert (= "not_found" (failure "code"))
            "an RPC failure arrives as the code it was raised with")
    (assert (= "no order A-9" (failure "message")))

    (assert (= "permission_denied" ((answer (curl "Explode" `{}`)) "code")))

    (def [placed _] (curl "PlaceOrder" `{"totalCents":"1500"}`))
    (assert (= "1500" ((json/decode placed) "totalCents"))
            "and a write round-trips through a client void has never met"))

  (print "interop ok — checked against " buf))

(if buf
  (run-interop)
  (print "interop skipped — `buf` is not on PATH (see buf.build/docs/installation); "
         "everything else in this suite still ran"))

(print "interop done")
