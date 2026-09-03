### void/dash/mount — the dashboard's routes, under [:dash :prefix].
###
### Its own routes, deliberately not `:void.admin/page`s: the admin may
### not be in the composition, and a dev dashboard must not drag a back
### office (with its db, authz and htmx-widget edges) into the process
### to draw a health tile. The mount is the admin's shape though — a
### route source projected once per table build, a fingerprinted asset
### behind the same gate as every page.
###
### **The gate is shut everywhere but on the developer's machine.** In
### the :dev profile the dashboard is open — the netrepl logic: this
### process already answers an unauthenticated REPL to whoever can reach
### it, and a read-only page of the same values adds nothing. In every
### other profile every route refuses until `[:dash :access]` names a
### predicate, and the refusal says which key opens it — the same
### construction as `[:admin :access]`, without the void/authz edge this
### package does not have. Pages are read-only; the one action (log
### levels) is separately behind `[:dash :allow-actions]`.

(import void/http/router :as router)
(import ./context :as ctx)
(import ./live :as live)
(import ./logs :as logs)
(import ./pages :as pages)
(import ./tap :as tap)
(import ./view :as view)

(def shut-message
  "What a closed dashboard answers with — the phrase names the key."
  (string "the dashboard is shut: [:dash :access] has not named a predicate. "
          "Set it to the function that decides who is an operator — "
          "{:dash {:access (fn [req] ...)}} — or run the :dev profile, "
          "where the dashboard is open on the developer's own machine."))

(defn- refuse
  "The gate: nil to pass, a 403 to stop."
  [req]
  (def deny @{:status 403
              :headers @{"content-type" "text/plain; charset=utf-8"}
              :body shut-message})
  (cond
    (ctx/setting :open?) nil
    (nil? (ctx/setting :access)) deny
    (let [[ok verdict] (protect ((ctx/setting :access) req))]
      (if (and ok verdict)
        nil
        @{:status 403
          :headers @{"content-type" "text/plain; charset=utf-8"}
          :body (if (and ok (string? verdict))
                  verdict
                  "the [:dash :access] predicate refused this request.")}))))

(defn- guarded [handler]
  (fn dash-gate [req]
    (or (refuse req) (handler req))))

# -- the live streams ----------------------------------------------------

(defn- overview-live [req]
  (live/stream req
               (fn [] (view/layout (pages/overview-body (ctx/boot))
                                   {:request req}))
               [live/overview-room]))

(defn- logs-live [req]
  (live/stream req
               (fn [] (view/layout (logs/logs-body {}) {:request req}))
               [live/logs-room]))

# -- the served sheet ----------------------------------------------------

(defn- asset-route [half type]
  (when-let [b (get (ctx/setting :assets {}) half)]
    (router/GET (string view/asset-prefix (b :file))
                (guarded (fn dash-asset [_req]
                           # a fresh mutable table per request, never a shared
                           # struct: the edge middlewares (CSRF's cookie, the
                           # security headers) *add* headers to whatever a
                           # handler returns, and a struct here answered every
                           # composition with void/security a 500 — which is
                           # an unstyled dashboard, because this route is the
                           # stylesheet
                           @{:status 200
                             :headers @{"content-type" type
                                        "cache-control" "private, max-age=31536000, immutable"}
                             :body (b :body)}))
                {:name (keyword "dash/asset-" (string half))})))

(defn- asset-routes []
  (filter truthy?
          [(asset-route :style "text/css; charset=utf-8")
           (asset-route :script "text/javascript; charset=utf-8")]))

# -- the whole thing -----------------------------------------------------

(defn routes
  ``The route source: every dash page under `[:dash :prefix]`, each
  behind the gate. Called once per route-table build. The group
  carries `[:dash :route-meta]` — how an application says something
  about the dashboard's routes this package cannot know (the admin's
  `:route-meta` idiom: an OpenAPI projection hiding the dashboard is
  `{:dash {:route-meta {:void.openapi/hidden true}}}`).``
  []
  (def children @[])
  (defn add [method pattern handler name]
    (array/push children
                (router/route method pattern (guarded handler) {:name name})))
  (each r (asset-routes) (array/push children r))
  (add :get "/" pages/overview :dash/overview)
  (add :get "/components" pages/components :dash/components)
  (add :get "/why" pages/why :dash/why)
  (add :get "/plugins" pages/plugins :dash/plugins)
  (add :get "/point" pages/point :dash/point)
  (add :get "/config" pages/config-page :dash/config)
  (add :get "/routes" pages/routes :dash/routes)
  (add :get "/route" pages/route :dash/route)
  (add :get "/deploy" pages/deploy-page :dash/deploy)
  (add :get "/logs" logs/index :dash/logs)
  (add :get "/logs/tail" logs/tail :dash/logs-tail)
  (add :post "/logs/level" logs/set-level :dash/logs-level)
  (add :get "/live" overview-live :dash/live)
  (add :get "/logs/live" logs-live :dash/logs-live)
  (add :get "/tap" tap/index :dash/tap)
  (add :get "/tap/:id" tap/show :dash/tap-value)
  (add :get "/tap/:id/node" tap/node :dash/tap-node)
  (add :get "/tap/:id/jdn" tap/jdn :dash/tap-jdn)
  (router/routes {}
    (router/group (ctx/prefix) (ctx/setting :route-meta {}) ;children)))
