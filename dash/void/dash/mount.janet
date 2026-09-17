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
### other profile every route refuses until a `:void.dash/gate` contribution names a
### predicate — a `:void.dash/gate` contribution, since a function is
### not a config value (`config explain` cannot print one) — and the
### refusal says which contribution opens it: the same construction as
### `[:admin :access]`, without the void/authz edge this package does
### not have. Pages are read-only; the one action (log
### levels) is separately behind `[:dash :allow-actions]`.

(import void/html/chrome :as chrome)
(import void/http/router :as router)
(import ./context :as ctx)
(import ./live :as live)
(import ./logs :as logs)
(import ./pages :as pages)
(import ./tap :as tap)

(def shut-message
  "What a closed dashboard answers with — the phrase names the key."
  (string "the dashboard is shut: nothing contributed :void.dash/gate. "
          "Contribute the predicate that decides who is an operator — "
          "{:name :app/operators :fn (fn [req] ...)} — or run the :dev profile, "
          "where the dashboard is open on the developer's own machine."))

(defn- refuse
  {:params [:any] :ret (or @{:status :number :headers @{:string :string} :body :string} :nil)
   :throws [:string]}
  "The gate: nil to pass, a 403 to stop."
  [req]
  (def deny @{:status 403
              :headers @{"content-type" "text/plain; charset=utf-8"}
              :body shut-message})
  (cond
    (ctx/setting :open?) nil
    (nil? (ctx/setting :gate)) deny
    (let [[ok verdict] (protect ((get (ctx/setting :gate) :fn) req))]
      (if (and ok verdict)
        nil
        @{:status 403
          :headers @{"content-type" "text/plain; charset=utf-8"}
          :body (if (and ok (string? verdict))
                  verdict
                  "the :void.dash/gate predicate refused this request.")}))))

(defn- guarded
  {:params [(fn [:any] :any)] :ret (fn [:any] :any)}
  "Wrap `handler` so every request meets the gate first — nil from
  `refuse` passes through to it, a 403 stops there."
  [handler]
  (fn dash-gate [req]
    (or (refuse req) (handler req))))

# -- the live streams ----------------------------------------------------

# The view a stream re-renders is **the handler itself**: `morph-stream`
# takes the lazy `html/page` response and renders it (html/render-now),
# so the live half and the ordinary response are one render path and not
# two that drift. And the stream's own request carries the page's query
# (the page opened it with `datastar/stream-url`), so a filtered log page
# stays filtered when it is morphed. Both were what the idiom got wrong
# here first — ADR-0043 §5, folded back into ADR-0037.

(defn- overview-live
  {:params [:any] :ret @{:status :number :body :any :headers @{:string :any}} :throws [:string]}
  "The overview's morph-stream, or the datastar-absent refusal."
  [req]
  (live/stream req (fn [] (pages/overview req)) [live/overview-room]))

(defn- logs-live
  {:params [:any] :ret @{:status :number :body :any :headers @{:string :any}} :throws [:string]}
  "The logs page's morph-stream, or the datastar-absent refusal."
  [req]
  (live/stream req (fn [] (logs/index req)) [live/logs-room]))

# -- the served sheet ----------------------------------------------------

(defn- asset-routes
  {:params []
   :ret @[{:route :boolean :method :keyword :pattern :string
           :handler (or :symbol :function) :meta {:keyword :any}}]
   :throws [:string]}
  "The dash's own stylesheet and script, each behind the gate."
  []
  (filter truthy?
          (seq [half :in [:style :script]]
            (chrome/asset-route half (get (ctx/setting :assets {}) half)
                                {:name (keyword "dash/asset-" (string half))
                                 :wrap guarded}))))

# -- the whole thing -----------------------------------------------------

(defn routes
  {:params [] :ret {:routes :boolean :global {:keyword :any} :children [:any]} :throws [:string]}
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
