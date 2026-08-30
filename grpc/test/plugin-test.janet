(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/proto :as proto)
(import void/grpc :as grpc)
(import void/grpc/codes :as codes)
(import void/grpc/connect :as connect)
(import void/grpc/service :as service)
(import void/grpc/mount :as mount)
(require "void/http/init")
(require "void/proto/init")

# -- the manifest ---------------------------------------------------------

(def report (plugin/dry-run {:plugins [:void/http :void/proto :void/grpc] :profile :test}))
(assert report "void/grpc dry-runs over the kernel and the codec")
(assert (get-in report [:extensions :void.grpc/codec]) "and declares its codec point")
(assert (= 2 (get-in report [:extensions :void.grpc/codec :contributions]))
        "with the two codecs the protocol defines in it")

(def [ok err] (protect (plugin/dry-run {:plugins [:void/http :void/grpc] :profile :test})))
(assert (not ok) "void/grpc without void/proto is a composition with no codec")
(assert (string/find "void/proto" (if (string? err) err (string/format "%q" err))))

(def boot (plugin/bootstrap {:plugins [:void/http :void/proto :void/grpc] :profile :test} true))

(def meta-keys (get-in boot [:extensions :void.http/route-meta-key :resolved] {}))
(each k [:void.grpc/service :void.grpc/method]
  (assert (get meta-keys k)
          (string/format "%q is declared, so a route may carry it (ADR-0005)" k)))

(def renderers (get-in boot [:extensions :void.http/error-renderer :resolved] []))
(def connect-renderer (first (filter |(= :void.grpc/error ($ :name)) renderers)))
(assert connect-renderer)
(assert (< (get connect-renderer :priority 1000) 900)
        "the Connect renderer runs before void/rest's problem+json: on an RPC route the client
        is a generated stub that reads one shape and not the other")

(def commands (get-in boot [:extensions :void.core/cli :resolved] []))
(def services-cmd (first (filter |(= :grpc/services ($ :name)) commands)))
(assert services-cmd)
(assert (services-cmd :read-only?) "listing methods changes nothing, so an agent may do it")

# -- config ----------------------------------------------------------------

(def settings (grpc/build-settings boot))
(assert (settings :mount))
(assert (not (settings :require-protocol-version))
        "the version header is not required by default — see the [:grpc] docs for why")
(assert (settings :describe-errors) "outside :prod an error's text reaches the developer")

(def prod (plugin/bootstrap {:plugins [:void/http :void/proto :void/grpc] :profile :prod
                             :config {:env @{}}}
                            true))
(assert (not ((grpc/build-settings prod) :describe-errors))
        "and in :prod it does not, because an unhandled error's text is somebody's internals")

(assert (not (first (protect (plugin/dry-run
                               {:plugins [:void/http :void/proto :void/grpc] :profile :test
                                :config {:cli {:grpc {:mount "yes please"}}}}))))
        "a [:grpc] slice that is not the shape the schema says fails the bootstrap")

# -- codes ------------------------------------------------------------------

(assert (= 16 (length codes/names)) "the sixteen gRPC codes, and no seventeenth")
(each name codes/names
  (assert (codes/code? name))
  (assert (int? (codes/http-status name)))
  (assert (int? (codes/number name))))
(assert (= 404 (codes/http-status :not_found)))
(assert (= 499 (codes/http-status :canceled)))
(assert (= :permission_denied (codes/code-for-status 403)))
(assert (= :resource_exhausted (codes/code-for-status 429))
        "which is what void/security's rate limiter raises")
(assert (= :unavailable (codes/code-for-status 503))
        "and what void/pressure sheds with")
(assert (= :invalid_argument (codes/code-for-status 418)) "an unnamed 4xx is the caller's fault")
(assert (= :internal (codes/code-for-status 507)) "and an unnamed 5xx is ours")

(assert (= :not_found ((codes/failure {:void.grpc/code :not_found :message "x"}) codes/key)))
(assert (= :permission_denied ((codes/failure {:http/status 403}) codes/key))
        "an HTTP abort from anywhere else in void is read as the code it means")
(assert (= :internal ((codes/failure "a bare panic") codes/key)))
(assert (= "hidden" ((codes/failure "a bare panic" "hidden") :message))
        "and a panic's own text is replaced when the caller says to")
(assert (nil? (codes/failure {:something :else}))
        "a raised dictionary that is neither is somebody else's to render")

(assert (not (first (protect (codes/error-value :nonsense "x"))))
        "a code that is not one of the sixteen is refused where it is written")

# -- codec selection ---------------------------------------------------------

(def codecs (get-in boot [:extensions :void.grpc/codec :resolved] []))
(assert (= :void.grpc/proto ((connect/codec-for codecs "application/proto") :name)))
(assert (= :void.grpc/proto ((connect/codec-for codecs "application/protobuf") :name))
        "the aliases a client might send are matched too")
(assert (= :void.grpc/json ((connect/codec-for codecs "application/json; charset=utf-8") :name))
        "and a content type with parameters is still that content type")
(assert (nil? (connect/codec-for codecs "text/plain")))
(assert (= :void.grpc/json ((connect/codec-by-name codecs "json") :name))
        "Connect's GET form names a codec by its short name")
(assert (deep= @["application/json" "application/proto"] (connect/content-types codecs)))

# -- [:grpc :mount] false leaves the routes off ------------------------------

(proto/load-file! "test/protos/orders.proto")
(defn h [_msg _req] {:count 0})
(grpc/defservice :shop.orders/OrderService
  (rpc :GetOrder h) (rpc :CountOrders h) (rpc :PlaceOrder h)
  (rpc :Explode h) (rpc :Slow h))

(assert (not (empty? (mount/describe))))
(def source (first (get-in boot [:extensions :void.http/route-source :resolved] [])))
(assert (function? (source :routes))
        "the route source is a function, because the services it projects are registered
        long after this manifest froze")

(set grpc/settings (merge (grpc/build-settings boot) {:mount false}))
(assert (empty? (((source :routes) boot) :children))
        "[:grpc :mount] false mounts nothing, for an application that wants the endpoint
        somewhere its own route source decides")
(set grpc/settings (grpc/build-settings boot))
(assert (not (empty? (((source :routes) boot) :children))))

# -- the CLI prints what it promises -----------------------------------------

(defn- captured [f]
  (def out @"")
  (with-dyns [:out out] (f))
  (string out))

(def printed (captured |((services-cmd :fn))))
(assert (string/find "/shop.orders.OrderService/GetOrder" printed))
(assert (string/find "GET" printed) "an idempotent method is shown as one")
(assert (string/find "shop.orders.Order" printed) "with the messages it speaks")
(assert (not (first (protect ((services-cmd :fn) "extra")))))

# -- and taking the plugin out leaves nothing behind --------------------------

(def without (plugin/bootstrap {:plugins [:void/http] :profile :test} true))
(assert (empty? (filter |(= :void/grpc ($ :name))
                        (get-in without [:extensions :void.http/route-source :resolved] [])))
        "no void/grpc, no RPC routes (Definition of Done, point 1)")
(assert (nil? (get-in without [:extensions :void.grpc/codec]))
        "and no codec point either")

(print "plugin ok")
