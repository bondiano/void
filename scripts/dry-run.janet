### CI gate: dry-run the full in-repo plugin composition — void/http +
### void/html + void/htmx + void/rest + void/openapi + void/db +
### void/db-sqlite + void/db-postgres + void/db-mysql + void/db-http +
### void/redis + void/redis-http + void/cache + void/jobs + void/pressure
### + void/obs (+ -http, -otlp) + void/crypto + void/auth + void/auth-http
### + void/auth-db + void/oauth + void/bus + void/bus-db + void/bus-jobs +
### void/kafka + void/kafka-bus + void/ws + void/ws-htmx + void/proto +
### void/grpc + void/mcp (+ -http, -obs) + void/admin (+ -jobs, -mcp) +
### void/storage (+ -http, -s3, -admin) + void/notify (+ -mail, -inapp,
### -webhook, -jobs) + void/dev + void/bench (+ its runtime probe) + the
### demo plugin on top of the core extension points. The plugin list below
### is the composition; the module path under it is a projection of
### scripts/packages.janet, so a package added to the graph is on the path
### here without a second edit.
###
### Runs bootstrap phases 1-5 (load, config, conditional, extension
### resolution, graph) and starts nothing; any validation failure exits
### non-zero with the batched error list. Then checks what the edges add
### up to — the HTTP chain, the edge, the lifecycle hooks and the error
### renderers — against the golden order below (ADR-0051). Run from anywhere:
###
###     janet scripts/dry-run.janet

(import ./packages :as packages)

# Every package in the graph, on the module path — the composition gate is
# the one place that loads all of them at once. void/fdwait is among them,
# so its native module has to be built first
# (janet scripts/bootstrap.janet, or cd fdwait && jpm build).
(packages/add-paths (packages/packages))

(import void/core/plugin :as plugin)
(import void/core/hooks :as hooks)
(import void/http/middleware :as mw)
(require "void/http/init")
(require "void/html/init")
(require "void/htmx/init")
(require "void/rest/init")
(require "void/openapi/init")
(require "void/db/init")
(require "void/db-sqlite/init")
(require "void/db-postgres/init")
(require "void/db-mysql/init")
(require "void/db/http")
(require "void/redis/init")
(require "void/redis/http")
(require "void/cache/init")
(require "void/cache/redis")
(require "void/cache/http")
(require "void/jobs/init")
(require "void/jobs/db")
(require "void/jobs/redis")
(require "void/pressure/init")
(require "void/pressure/http")
(require "void/obs/init")
(require "void/obs/http")
(require "void/obs/otlp")
(require "void/crypto/init")
(require "void/auth/init")
(require "void/auth/http")
(require "void/auth/db")
(require "void/auth/oauth")
(require "void/oauth/init")
(require "void/tls/init")
(require "void/i18n/init")
(require "void/datastar/init")
(require "void/authz/init")
(require "void/authz/http")
(require "void/security/init")
(require "void/mail/init")
(require "void/mail/jobs")
(require "void/mail/auth")
(require "void/bus/init")
(require "void/bus/db")
(require "void/bus/jobs")
(require "void/kafka/init")
(require "void/kafka/bus")
(require "void/ws/init")
(require "void/ws/htmx")
(require "void/proto/init")
(require "void/grpc/init")
(require "void/mcp/init")
(require "void/mcp/http")
(require "void/mcp/obs")
(require "void/admin/init")
(require "void/admin/jobs")
(require "void/admin/mcp")
(require "void/storage/init")
(require "void/storage/http")
(require "void/storage/s3")
(require "void/storage/admin")
(require "void/notify/init")
(require "void/notify/mail")
(require "void/notify/inapp")
(require "void/notify/webhook")
(require "void/notify/jobs")
(require "void/dash/init")
(require "void/dev/init")
(require "void/bench/init")
(require "void/bench/probe")
# examples/demo is a single plugin file, not a package: no project.janet
# puts it on a path, so it is required by where it lies.
(require "../examples/demo/plugin")

(def composition
  {:plugins [:void/http :void/html :void/htmx :void/rest :void/openapi
                             :void/db :void/db-sqlite :void/db-postgres :void/db-mysql :void/db-http
                             :void/redis :void/redis-http
                             :void/cache :void/cache-redis :void/cache-http
                             :void/jobs :void/jobs-db :void/jobs-redis
                             :void/pressure :void/pressure-http
                             :void/obs :void/obs-http :void/obs-otlp
                             :void/crypto :void/auth :void/auth-http :void/auth-db :void/auth-oauth
                             :void/oauth :void/tls :void/i18n :void/datastar
                             :void/authz :void/authz-http :void/security
                             :void/mail :void/mail-jobs :void/mail-auth
                             :void/bus :void/bus-db :void/bus-jobs
                             :void/kafka :void/kafka-bus
                             :void/ws :void/ws-htmx
                             :void/proto :void/grpc
                             :void/mcp :void/mcp-http :void/mcp-obs
                             :void/admin :void/admin-jobs :void/admin-mcp
                             :void/storage :void/storage-http :void/storage-s3 :void/storage-admin
                             :void/notify :void/notify-mail :void/notify-inapp :void/notify-webhook :void/notify-jobs
                             :void/dash
                             :void/dev :void/bench :bench/probe :demo/greeter]
                   :profile :dev
   # three drivers now provide :void/db-driver, two stores provide
   # :void/cache-store, and three backends provide :void/jobs-backend —
   # exactly the ambiguity the kernel refuses to resolve on its own. The
   # gate says which, the way an application's config would (see
   # void/db-postgres, void/cache-redis, void/jobs-redis)
   # the bus picks its backend by *name* rather than by component
   # (void/bus/backend on why): the gate says which, the way an
   # application's config would
   :config {:cli {:bus {:backend :db}
                  :void/db-driver {:impl :db.sqlite/driver}
                  :void/cache-store {:impl :cache/redis}
                  :void/jobs-backend {:impl :jobs/redis}
                  # and three more, now that void/auth ships memory
                  # stores and void/auth-db ships database ones
                  :void/auth-user-store {:impl :auth.db/users}
                  :void/auth-token-store {:impl :auth.db/tokens}
                  :void/auth-challenge-store {:impl :auth.db/challenges}
                  # and two stores provide :void/storage-store, once
                  # void/storage-s3 is in the composition
                  :void/storage-store {:impl :storage/s3}
                  :storage-s3 {:endpoint "http://minio.invalid:9000" :bucket "gate"
                               :access-key "gate" :secret-key "gate-secret"}}}})

(def report (plugin/dry-run composition))

(printf "dry-run ok (profile %q)" (report :profile))
(printf "  plugins:    %j (active: %j)" (report :plugins) (report :active))
(printf "  components: %j" (report :components))
(printf "  extensions:")
(each name (sorted (keys (report :extensions)))
  (def e (get-in report [:extensions name]))
  (printf "    %q  owner=%q contributions=%d" name (e :owner) (e :contributions)))

# -- the composition's order, against the golden one (ADR-0051) -----------
#
# Order is edges to named anchors now, and a sort answers it; what the
# edges add up to in the full composition is the thing a reviewer
# checks by eye, so it is written down here and a drift fails the gate.
# The HTTP chain and the edge are the whole order, anchors included, as
# `middleware/order` answers it. Hooks are not a total order worth
# pinning — most handlers only say which side of an anchor they are on
# — so they are checked as the pairs the plan names (ADR-0051, §F of
# the wave's plan): the one before the other in the same hook.

(def golden-chain
  [:void.http/panic-guard :void.http/guarded
   :void.http/request-id :void.pressure/shed :void.security/rate-ip
   :void.http.stage/on-send
   :void.obs/request
   :void.http.stage/on-request :void.http.stage/pre-parsing
   :void.http/parsing :void.http/session :void.auth/identity :void.auth/scopes
   :void.http/authenticated
   :void.i18n/locale
   :void.http/scoped
   :void.security/rate-subject :void.security/csrf
   :void.http/verified
   :void.db/load
   :void.http/loaded
   :void.authz/enforce
   :void.http/authorized
   :void.cache/response
   :void.http.stage/pre-validation
   :void.rest/validate
   :void.http/validated
   :void.db/txn
   :void.http/responding
   :void.datastar/morph :void.html/render :void.htmx/partial :void.rest/serialize
   :void.http.stage/pre-serialization :void.http.stage/pre-handler])

(def golden-edge
  [:void.i18n/scope :void.http.edge/scoped
   :void.admin/method-override :void.security/cors :void.security/headers])

(def golden-hook-pairs
  "hook -> [earlier later] pairs that must hold."
  {:config-loaded [[:obs/capture-boot :obs/logging]]
   :before-start [[:html/build-context :http/build-table]
                  [:rest/build-context :http/build-table]
                  [:openapi/build-context :http/build-table]
                  [:i18n/install-catalog :http/build-table]
                  [:security/configure :http/build-table]
                  [:auth-http/capture-config :http/build-table]
                  [:authz-http/capture-config :http/build-table]
                  [:cache-http/capture-config :http/build-table]
                  [:admin/build-context :admin-jobs/policies]
                  [:admin-jobs/policies :http/build-table]
                  [:dash/build-context :http/build-table]
                  [:notify-webhook/configure :http/build-table]
                  [:http/build-table :mail-jobs/install]
                  [:http/build-table :notify-jobs/install]]
   :after-start [[:authz-http/deny-by-default :bus/consume]
                 [:admin/warn-when-shut :bus/consume]
                 [:mail/queue-check :bus/consume]
                 [:bus-db/outbox :bus/consume]
                 [:bus/consume :bus-jobs/bridge]
                 [:bus/consume :obs-http/ready]
                 [:obs/instrument :obs-http/ready]
                 [:security/limiter-store :obs-http/ready]]
   :before-stop [[:obs-http/draining :bus-jobs/unbridge]
                 [:obs-http/draining :obs/uninstrument]
                 [:bus-jobs/unbridge :bus/stop-consuming]]})

(def golden-renderers
  "Error renderers that must be asked in this order."
  [:void.grpc/error :void.rest/problem])

(defn- step-names
  {:params [[:any]] :ret [:keyword]}
  "The names `middleware/order` answers, anchors included."
  [steps]
  (map |(if ($ :anchor) ($ :name) (get-in $ [:value :name])) steps))

(defn- before?
  {:params [[:keyword] :keyword :keyword] :ret :boolean}
  "Does `a` come before `b` in `names`, both present?"
  [names a b]
  (def i (index-of a names))
  (def j (index-of b names))
  (and (not (nil? i)) (not (nil? j)) (< i j)))

(defn- order-drift
  {:params [Boot] :ret @[:string]}
  "Every way the composition's order differs from the golden one."
  [boot]
  (def requires (tabseq [p :in (boot :active)]
                  p (get-in boot [:manifests p :requires] {})))
  (defn contribs
    {:params [:keyword] :ret [:any]}
    [point] (get-in boot [:extensions point :contributions] []))
  (def chain (step-names (mw/order (contribs :void.http/middleware)
                                   {:requires requires})))
  (def edge (step-names (mw/order (contribs :void.http/edge)
                                  {:anchors mw/edge-anchors :what "edge wrapper"
                                   :requires requires})))
  (def renderers (map |($ :name) (get-in boot [:extensions :void.http/error-renderer :resolved] [])))
  (def diffs @[])
  (unless (= (tuple ;chain) golden-chain)
    (array/push diffs (string/format "HTTP chain:\n      want %j\n      got  %j" golden-chain chain)))
  (unless (= (tuple ;edge) golden-edge)
    (array/push diffs (string/format "edge:\n      want %j\n      got  %j" golden-edge edge)))
  (loop [[hook pairs] :in (sorted (pairs golden-hook-pairs))
         :let [names (map |($ :name) (hooks/handlers (boot :hooks) hook))]
         [a b] :in pairs
         :unless (before? names a b)]
    (array/push diffs (string/format "hook %q: %q must run before %q (got %j)" hook a b names)))
  (unless (before? renderers ;golden-renderers)
    (array/push diffs (string/format "error renderers: want %j in this order, got %j"
                                     golden-renderers renderers)))
  diffs)

(let [diffs (order-drift (plugin/bootstrap composition true))]
  (unless (empty? diffs)
    (errorf "composition order drifted from the golden one (ADR-0051):\n  - %s"
            (string/join diffs "\n  - ")))
  (printf "  order:      golden (%d chain steps, %d edge steps, %d hook pairs, %d renderers)"
          (length golden-chain) (length golden-edge)
          (sum (map length (values golden-hook-pairs))) (length golden-renderers)))
