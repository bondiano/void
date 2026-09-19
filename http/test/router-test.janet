(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/middleware :as mw)
(import void/core/meta :as meta)

# -- pattern compilation -------------------------------------------------

(def p (router/compile-pattern "/orders/:id"))
(assert (= [:id] (p :params)) "param captured in order")
(assert (nil? (p :static)) "parametric pattern is not static")
(assert (deep= @["42"] (peg/match (p :peg) "/orders/42")) "peg matches and captures")
(assert (nil? (peg/match (p :peg) "/orders/42/x")) "no trailing segments")
(assert (nil? (peg/match (p :peg) "/orders/")) "empty param does not match")

(def sp (router/compile-pattern "/files/*path"))
(assert (deep= @["a/b.txt"] (peg/match (sp :peg) "/files/a/b.txt")) "splat spans slashes")
(assert (deep= @[""] (peg/match (sp :peg) "/files/")) "splat may be empty")

(assert (= "/health" ((router/compile-pattern "/health") :static))
        "no captures -> static fast path")

(assert (not (first (protect (router/compile-pattern "/a/*x/b"))))
        "non-terminal splat is rejected")

# -- meta keys used below ------------------------------------------------

(def meta-keys
  {:void.http/middleware (meta/declare-key :void.http/middleware
                           :schema [:vector :keyword] :merge :concat)
   :void.http/timeout (meta/declare-key :void.http/timeout
                        :schema [:number {:min 0}] :merge :restrict
                        :allow? (fn [outer inner] (<= inner outer)))
   :void.http/max-body (meta/declare-key :void.http/max-body
                         :schema [:int {:min 0}] :merge :restrict
                         :allow? (fn [outer inner] (<= inner outer)))
   :app/flag (meta/declare-key :app/flag :schema :boolean)})

# -- build-table: happy path ---------------------------------------------

(def trace @[])
(defn- tracing
  {:params [:keyword] :ret (fn [HttpHandler] HttpHandler)}
  "A middleware factory that records `name` to `trace` before calling
  through — the whole observation mechanism the ordering assertions
  below read."
  [name]
  (fn [handler]
    (fn [req]
      (array/push trace name)
      (handler req))))

(def middleware
  [{:plugin :void/obs :value {:name :obs
                              :after :void.http.stage/on-send
                              :before :void.http.stage/on-request
                              :wrap (tracing :obs)}}
   {:plugin :void/http :value {:name :guard :before :void.http/guarded
                               :wrap (tracing :guard)}}
   {:plugin :my-app :value {:name :audit
                            :after :void.http/validated :before :void.http/responding
                            :named true
                            :wrap (tracing :audit)}}
   {:plugin :my-app :value {:name :admin-only
                            :after :void.http/loaded :before :void.http/authorized
                            :when |(get $ :app/flag)
                            :wrap (tracing :admin-only)}}])

(def src
  (router/routes {:void.http/timeout 30}
    (router/GET "/health" (fn [req] {:status 200 :body "up"}) {:name :health})
    (router/GET "/orders/:id" 'test-support.fixtures.handlers/echo-id
      {:name :orders/show :void.http/timeout 5})
    (router/group "/admin" {:app/flag true :void.http/middleware [:audit]}
      (router/GET "/users" 'test-support.fixtures.handlers/hello
        {:name :admin/users}))
    (router/ANY "/misc/*rest" (fn [req] {:status 200 :body "any"})
      {:name :misc})))

(def table
  (router/build-table
    {:sources [{:name :app :routes src}]
     :meta-keys meta-keys
     :middleware middleware}))

(assert (= 4 (length (table :routes))) "all routes built")

# static + dynamic matching
(def [health hp] (router/lookup table :get "/health"))
(assert (= :health (health :name)) "static route matches by lookup")
(assert (= {} hp))

(def [orders op] (router/lookup table :get "/orders/42"))
(assert (= :orders/show (orders :name)))
(assert (= "42" (op :id)) "captures land in params by name")

(assert (nil? (router/lookup table :post "/orders/42")) "wrong method does not match")
(assert (router/lookup table :head "/health") "HEAD falls back to GET")
(assert (router/lookup table :delete "/misc/a/b") ":any matches every method")
(assert (= [:get :head] (freeze (router/allowed-methods table "/orders/42")))
        "allowed-methods lists the 405 Allow set")
(assert (empty? (router/allowed-methods table "/nope")) "no methods for unknown path")

# metadata merge: restrict + provenance
(assert (= 5 (get-in table [:by-name :orders/show :meta :void.http/timeout]))
        "route layer tightens the global timeout")
(assert (= 30 (get-in health [:meta :void.http/timeout]))
        "global default reaches other routes")

# :restrict binds a route to the *layers above it* and to nothing else. A
# source that declares no ceiling declares no ceiling: the one route in an
# application that has to accept a 25 MiB webhook says so on itself, and
# the rest of the application keeps [:http :max-body] — which is the
# server's fallback for a route that names nothing, not an outer metadata
# layer (examples/hub, 6.6).
(def raised
  (router/build-table
    {:sources [{:name :app
                :routes (router/routes {}
                          (router/POST "/in" (fn [_] nil)
                                       {:name :in/receive
                                        :void.http/max-body 26214400}))}]
     :meta-keys meta-keys}))
(assert (= 26214400 (get-in raised [:by-name :in/receive :meta :void.http/max-body]))
        "a route under no ceiling names its own")

# middleware chains: edge order, :when by metadata, :named opt-in
(array/clear trace)
(def resp (router/dispatch table @{:method :get :path "/orders/42"}))
(assert (= "42" (resp :body)) "dispatch runs the chain and the symbol handler")
(assert (= [:guard :obs] (freeze trace))
        "global middleware in edge order; :named and failing :when excluded")

(array/clear trace)
(router/dispatch table @{:method :get :path "/admin/users"})
(assert (= [:guard :obs :admin-only :audit] (freeze trace))
        ":when passes on group meta; :named selected via :void.http/middleware")

(assert (nil? (router/dispatch table @{:method :get :path "/nope"}))
        "no match -> nil (the server decides 404)")

# request enrichment
(def req @{:method :get :path "/orders/7"})
(router/dispatch table req)
(assert (= :orders/show (get-in req [:void/route :name])) ":void/route is set")
(assert (= "7" (get-in req [:params :id])))

# -- :route-aware — :wrap sees the route at build, never the request ---

(def seen-at-build @[])
(def aware-table
  (router/build-table
    {:sources [{:name :app :routes src}]
     :meta-keys meta-keys
     :middleware
     [;middleware
      {:plugin :my-app
       :value {:name :timeout-tag
               :after :void.http/validated :before :void.http/responding
               :route-aware true
               :when |(not (nil? (get $ :void.http/timeout)))
               :wrap (fn [handler rmeta]
                       (array/push seen-at-build (rmeta :name))
                       # the spec lives in the closure: whatever the
                       # request carries is not consulted
                       (def tag (string "t=" (rmeta :void.http/timeout)))
                       (fn [req]
                         (def resp (handler req))
                         (merge resp {:body (string (resp :body) " " tag)})))}}
      {:plugin :my-app
       :value {:name :plain :after :void.http/guarded
               :wrap (fn [handler] handler)}}]}))
(assert (deep= (sorted seen-at-build) @[:admin/users :health :misc :orders/show])
        "a :route-aware :wrap is called once per route at table build, with that route's merged meta")
(assert (= "42 t=5" ((router/dispatch aware-table @{:method :get :path "/orders/42"}) :body))
        "the wrapper used the route's own value (5 overrides the group's 30)")
(assert (= "up t=30" ((router/dispatch aware-table @{:method :get :path "/health"}) :body))
        "and the inherited one where the route did not override")
(def [aware-entry _] (router/lookup aware-table :get "/orders/1"))
(assert (= "1 t=5" (((aware-entry :chain)
                     @{:method :get :path "/orders/1" :params {:id "1"}
                       :void/route {:meta {:void.http/timeout 999 :name :forged}}})
                    :body))
        "a forged :void/route on the request changes nothing — the meta was read at build")
(assert (not (first (protect (router/build-table
                               {:sources [{:name :app :routes src}]
                                :meta-keys meta-keys
                                :middleware
                                [;middleware
                                 {:plugin :my-app
                                  :value {:name :unary :after :void.http/guarded
                                          # a v1 :wrap of one argument, wrongly flagged
                                          :route-aware true
                                          :wrap (fn [handler] handler)}}]}))))
        "a :route-aware contribution whose :wrap takes one argument fails the table build, not a request")

# -- the chain as data: edges, plugins, and who declined why -------------

(def ex-orders (router/explain-route table "/orders/42"))
(assert (deep= (map |[($ :name) ($ :plugin) ($ :before)] (ex-orders :chain))
               @[[:guard :void/http :void.http/guarded]
                 [:obs :void/obs :void.http.stage/on-request]])
        ":chain carries name, the contributing plugin and its edges, outermost first")
(assert (deep= (sorted (keys (get-in ex-orders [:chain 0]))) @[:before :name :plugin])
        "and nothing else — there is no phase")
(assert (deep= (map |[($ :name) ($ :reason)] (ex-orders :declined))
               @[[:admin-only :when] [:audit :named]])
        "the declined are kept with their reason, in chain order: :when refused the meta, :named was not listed")
(assert (string/find "declined:" (ex-orders :text)) "and the human text lists them")
(assert (string/find ":admin-only (:my-app) — :when declined" (ex-orders :text)))
(assert (empty? ((router/explain-route table "/admin/users") :declined))
        "a route that takes everything declines nothing")

# -- placement by neighbour: an edge to another middleware ----------------

(def placed
  (router/build-table
    {:sources [{:name :app :routes src}]
     :meta-keys meta-keys
     :middleware
     [;middleware
      {:plugin :my-app :value {:name :after-obs :after :obs :wrap (tracing :after-obs)}}
      {:plugin :my-app :value {:name :chained :after :after-obs :wrap (tracing :chained)}}
      {:plugin :my-app :value {:name :outermost :before :guard :wrap (tracing :outermost)}}]}))
(def placed-ex (router/explain-route placed "/health"))
(assert (deep= (map |($ :name) (placed-ex :chain))
               @[:outermost :guard :obs :after-obs :chained])
        ":after a neighbour is right after it, :before right before it, and a relative may target a relative")
(assert (= :obs (get-in placed-ex [:chain 3 :after])) "the step remembers what it was placed after")
(assert (string/find ":after-obs (after :obs)" (placed-ex :text)))
(array/clear trace)
(router/dispatch placed @{:method :get :path "/health"})
(assert (= [:outermost :guard :obs :after-obs :chained] (freeze trace))
        "and the chain runs in that order")

(defn- build-error
  {:params [[:any] (or {:keyword :any} :nil)] :ret :string}
  "Builds the route table with `mws` appended to the base middleware
  (and `requires` when given), asserts the build fails, and returns
  the error text for the caller to search."
  [mws &opt requires]
  (def [ok err] (protect (router/build-table {:sources [{:name :app :routes src}]
                                              :meta-keys meta-keys
                                              :requires requires
                                              :middleware [;middleware ;mws]})))
  (assert (not ok))
  (string err))

(def unknown (build-error [{:plugin :my-app :value {:name :lost :after :obz :wrap identity}}]))
(assert (string/find "middleware :lost (from :my-app): :after :obz is unknown" unknown)
        "a name nobody contributes fails the build")
(assert (string/find "did you mean :obs?" unknown) "with a did-you-mean")
(assert (string/find "route table errors:" unknown) "batched with the other table errors")

(def cycle (build-error [{:plugin :my-app :value {:name :a :after [:void.http/guarded :b] :wrap identity}}
                         {:plugin :my-app :value {:name :b :after :a :wrap identity}}]))
(assert (string/find "middleware order is a cycle: :a -> :b -> :a" cycle)
        "middleware that point at each other are refused with the path")

(def loose (build-error [{:plugin :my-app :value {:name :loose :wrap identity}}]))
(assert (string/find "middleware :loose (from :my-app) is not placed" loose)
        "a middleware tied to no anchor fails the build")
(def stale (build-error [{:plugin :my-app :value {:name :old :phase 7000 :wrap identity}}]))
(assert (string/find "(:phase was removed in ADR-0051)" stale)
        "a leftover :phase is told where it went")

(def unrequired
  (build-error [{:plugin :my-app :value {:name :spy :after :obs :wrap identity}}]
               {:my-app {:void/http ">=0.0.1"} :void/obs {:void/http ">=0.0.1"}}))
(assert (string/find "middleware :spy (from :my-app): :after :obs belongs to :void/obs, which :my-app does not require"
                     unrequired)
        "a neighbour of a plugin the contributor does not require is refused")
(assert (router/build-table {:sources [{:name :app :routes src}]
                             :meta-keys meta-keys
                             :requires {:my-app {:void/obs ">=0.0.1"}}
                             :middleware [;middleware
                                          {:plugin :my-app
                                           :value {:name :spy :after :obs :wrap identity}}]})
        "and allowed once it is required")

# the point's cross-check, at boot: what it can tell without plugins
(def check (mw/placement-check mw/anchors "middleware"))
(assert (nil? (check [{:name :one :after :void.http/guarded :wrap identity}
                      {:name :two :after :one :wrap identity}])))
(assert (string/find "ADR-0051"
                     (last (protect (check [{:name :old :phase 10 :after :void.http/guarded
                                             :wrap identity}]))))
        "a leftover :phase fails the boot even when the contribution is placed")
(assert (not (first (protect (check [{:name :neither :wrap identity}]))))
        "and so does one placed nowhere")
(assert (not (first (protect (check [{:name :lost :after :nobody :wrap identity}]))))
        "and one pointing at a name nobody has")

# -- stages are anchors: a route's hooks go in at theirs -----------------

(def staged
  (router/build-table
    {:sources [{:name :app :routes src}]
     :meta-keys meta-keys
     :middleware middleware
     :stage-hooks {:on-request [(fn [_] (array/push trace :on-request) nil)]
                   :pre-handler [(fn [_] (array/push trace :pre-handler) nil)]
                   :on-send [(fn [_ resp] (array/push trace :on-send) resp)]}}))
(array/clear trace)
(router/dispatch staged @{:method :get :path "/admin/users"})
(assert (= [:guard :obs :on-request :admin-only :audit :pre-handler :on-send] (freeze trace))
        "request hooks run at their anchor; the response hook at :on-send runs on the way out")
(assert (deep= (get-in staged [:by-name :admin/users :middleware])
               [:guard :void.http.stage/on-send :obs :void.http.stage/on-request
                :admin-only :audit :void.http.stage/pre-handler])
        "a stage wrapper sits at its anchor; an anchor with no hooks is not in the chain")
(def staged-ex (router/explain-route staged "/admin/users"))
(assert (get-in staged-ex [:chain 1 :stage]) "a stage wrapper is marked as one")
(assert (string/find ":void.http.stage/on-send (stage)" (staged-ex :text)))

# -- no path between two middleware: the order is still one --------------

(defn- two-plugins
  {:params [[:any]] :ret @[:keyword]}
  "The /health chain names with `extra` appended to the base
  middleware."
  [extra]
  (def t (router/build-table {:sources [{:name :app :routes src}]
                              :meta-keys meta-keys
                              :middleware [;middleware ;extra]}))
  (get-in t [:by-name :health :middleware]))

(def zeta {:plugin :void/a :value {:name :zeta :after :void.http/validated :wrap identity}})
(def alpha {:plugin :void/b :value {:name :alpha :after :void.http/validated :wrap identity}})
(assert (deep= [:guard :obs :alpha :zeta] (two-plugins [zeta alpha]))
        "two middleware at one anchor go by name")
(assert (deep= (two-plugins [zeta alpha]) (two-plugins [alpha zeta]))
        "whichever came first")
(assert (empty? ((router/explain-route table "/health") :warnings))
        "and nothing is warned about: no path between them is what was declared")

# -- late binding --------------------------------------------------------

(def henv (require "test-support/fixtures/handlers"))
(def old-echo (get-in henv ['echo-id :value]))
(put-in henv ['echo-id :value] (fn [req] {:status 200 :body "patched"}))
(assert (= "patched" ((router/dispatch table @{:method :get :path "/orders/1"}) :body))
        "redefined handler is live without a table rebuild")
(put-in henv ['echo-id :value] old-echo)

# -- url-for -------------------------------------------------------------

(assert (= "/orders/a%2Fb" (router/url-for table :orders/show {:id "a/b"}))
        "path params are percent-encoded")
(assert (= "/health?page=2" (router/url-for table :health nil {:page 2})))
(assert (= "/misc/a/b.c" (router/url-for table :misc {:rest "a/b.c"}))
        "splat keeps its slashes")
(assert (not (first (protect (router/url-for table :orders/show {}))))
        "missing param is an error")
(assert (not (first (protect (router/url-for table :nope))))
        "unknown name is an error")

# -- explain-route -------------------------------------------------------

(def ex (router/explain-route table "/orders/42"))
(assert (= :orders/show (ex :name)))
(assert (= "42" (get-in ex [:params :id])))
(assert (= 5 (get-in ex [:meta :void.http/timeout])))
(def hist (get-in ex [:layers :void.http/timeout]))
(assert (= 2 (length hist)) "both layers recorded for the timeout")
(assert (= :route (get (last hist) :source)) "the route layer set the final value")
(assert (string/find "timeout" (ex :text)) "human text mentions the key")
(assert (= :app (ex :source)) "the route-source is named")
(assert (deep= (ex :middleware) [:guard :obs])
        "the resolved middleware chain, outermost first")
(assert (string/find "middleware:" (ex :text)) "human text lists the chain")
(assert (empty? (ex :warnings)))
(assert (nil? (router/explain-route table "/nope")) "no match -> nil")

# -- build errors are batched --------------------------------------------

(def bad
  (router/routes {}
    (router/GET "/a" (fn [_] nil) {:name :dup})
    (router/GET "/b" (fn [_] nil) {:name :dup})           # duplicate name
    (router/GET "/c" (fn [_] nil) {})                     # missing name
    (router/GET "/d" 'test-support.fixtures.handlers/nope
      {:name :bad-handler})                               # unresolvable symbol
    (router/GET "/e" (fn [_] nil)
      {:name :bad-meta :void.http/timeout -1})            # schema violation
    (router/GET "/f" (fn [_] nil)
      {:name :typo :void.htp/timeout 1})                  # unknown key
    (router/GET "/g" (fn [_] nil)
      {:name :loosens :void.http/timeout 60})))           # restrict loosening

(def [ok err]
  (protect (router/build-table
             {:sources [{:name :app :routes (router/routes {:void.http/timeout 30}
                                              (bad :children))}]
              :meta-keys meta-keys})))
(assert (not ok) "bad table fails")
(each needle ["already taken" ":name is required" "does not resolve"
              "did you mean" "may only tighten"]
  (assert (string/find needle err) (string "batched error mentions " needle)))

# bare handler symbol without env
(assert (not (first (protect (router/build-table
                               {:sources [{:name :x
                                           :routes (router/GET "/x" 'bare {:name :x})}]
                                :meta-keys {}}))))
        "bare symbol without :env fails at build")

# bare symbol with env resolves
(def benv (curenv))
(defn my-local-handler
  {:params [:any] :ret HttpResponse}
  "A handler bound as a bare symbol with an explicit :env, to prove
  that path resolves without going through a declaring module."
  [req] {:status 200 :body "local"})
(def btab (router/build-table
            {:sources [{:name :x :env benv
                        :routes (router/GET "/x" 'my-local-handler {:name :x})}]
             :meta-keys {}}))
(assert (= "local" ((router/dispatch btab @{:method :get :path "/x"}) :body))
        "bare symbol resolves in the declaring env")

# -- defroutes sugar -----------------------------------------------------

(defn dr-home
  {:params [:any] :ret HttpResponse}
  "The defroutes-sugar app's root handler, named only by its own
  symbol — proves a bare handler names its route."
  [req] {:status 200 :body "home"})
(defn dr-create
  {:params [:any] :ret HttpResponse}
  "Answers creation with 201 — its route gives an explicit :name, to
  prove that wins over the symbol-derived default."
  [req] {:status 201 :body "created"})
(defn dr-users
  {:params [:any] :ret HttpResponse}
  "A handler nested under the sugar's admin group, to prove group
  children expand and inherit the group's metadata."
  [req] {:status 200 :body "users"})

(router/defroutes :sugar/app {:void.http/timeout 30}
  (GET "/" dr-home)
  (POST "/entries" dr-create {:name :entries/create :app/flag true})
  (group "/admin" {:app/flag true}
    (GET "/users" dr-users))
  (router/GET "/raw" (fn [_] {:status 200 :body "raw"}) {:name :raw}))

(plugin/defplugin sugar/app :version "0.0.1")

(def sugar-source (first (get-in manifest [:contributes :void.http/route-source])))
(assert (= :sugar/app (sugar-source :name)) "defroutes contributes a named route source")

(def sugar-table
  (router/build-table {:sources [sugar-source] :meta-keys meta-keys}))

(def [sugar-home _] (router/lookup sugar-table :get "/"))
(assert (= :dr-home (sugar-home :name)) "a bare handler symbol names its route")
(assert (= 'dr-home (sugar-home :handler)) "and is quoted for late binding")
(assert (not (sugar-home :no-reload)) "so the route reloads with the module")
(assert (= 30 (get-in sugar-home [:meta :void.http/timeout]))
        "the leading dictionary is the global metadata layer")

(def [sugar-create _] (router/lookup sugar-table :post "/entries"))
(assert (= :entries/create (sugar-create :name)) "an explicit :name wins")
(assert (get-in sugar-create [:meta :app/flag]) "route metadata is kept")

(def [sugar-users _] (router/lookup sugar-table :get "/admin/users"))
(assert (= :dr-users (sugar-users :name)) "group children expand too")
(assert (get-in sugar-users [:meta :app/flag]) "under the group metadata layer")

(def [sugar-raw _] (router/lookup sugar-table :get "/raw"))
(assert (sugar-raw :no-reload) "an unrecognized form is spliced in as plain data")

(assert (= "home" ((router/dispatch sugar-table @{:method :get :path "/"}) :body))
        "handlers resolve in the declaring module env")

(assert (not (first (protect (macex1 '(router/defroutes "app" (GET "/" dr-home))))))
        "the route source name must be a keyword")
(assert (not (first (protect (macex1 '(router/defroutes :app (GET "/"))))))
        "a method form takes a pattern and a handler")

# -- atomic swap ---------------------------------------------------------

(def cell (router/cell table))
(assert (= table (router/current cell)))
(router/swap! cell btab)
(assert (= btab (router/current cell)) "swap! replaces the table atomically")

(print "router-test ok")
