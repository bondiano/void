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
   :app/flag (meta/declare-key :app/flag :schema :boolean)})

# -- build-table: happy path ---------------------------------------------

(def trace @[])
(defn- tracing [name]
  (fn [handler]
    (fn [req]
      (array/push trace name)
      (handler req))))

(def middleware
  [{:plugin :void/obs :value {:name :obs :phase mw/phase/observability
                              :wrap (tracing :obs)}}
   {:plugin :void/http :value {:name :guard :phase mw/phase/panic-guard
                               :wrap (tracing :guard)}}
   {:plugin :my-app :value {:name :audit :phase mw/phase/business :named true
                            :wrap (tracing :audit)}}
   {:plugin :my-app :value {:name :admin-only :phase mw/phase/authz
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
(def [health hp] (router/match table :get "/health"))
(assert (= :health (health :name)) "static route matches by lookup")
(assert (= {} hp))

(def [orders op] (router/match table :get "/orders/42"))
(assert (= :orders/show (orders :name)))
(assert (= "42" (op :id)) "captures land in params by name")

(assert (nil? (router/match table :post "/orders/42")) "wrong method does not match")
(assert (router/match table :head "/health") "HEAD falls back to GET")
(assert (router/match table :delete "/misc/a/b") ":any matches every method")
(assert (= [:get :head] (freeze (router/allowed-methods table "/orders/42")))
        "allowed-methods lists the 405 Allow set")
(assert (empty? (router/allowed-methods table "/nope")) "no methods for unknown path")

# metadata merge: restrict + provenance
(assert (= 5 (get-in table [:by-name :orders/show :meta :void.http/timeout]))
        "route layer tightens the global timeout")
(assert (= 30 (get-in health [:meta :void.http/timeout]))
        "global default reaches other routes")

# middleware chains: phases, :when by metadata, :named opt-in
(array/clear trace)
(def resp (router/dispatch table @{:method :get :path "/orders/42"}))
(assert (= "42" (resp :body)) "dispatch runs the chain and the symbol handler")
(assert (= [:guard :obs] (freeze trace))
        "global middleware in phase order; :named and failing :when excluded")

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
(defn my-local-handler [req] {:status 200 :body "local"})
(def btab (router/build-table
            {:sources [{:name :x :env benv
                        :routes (router/GET "/x" 'my-local-handler {:name :x})}]
             :meta-keys {}}))
(assert (= "local" ((router/dispatch btab @{:method :get :path "/x"}) :body))
        "bare symbol resolves in the declaring env")

# -- defroutes sugar -----------------------------------------------------

(defn dr-home [req] {:status 200 :body "home"})
(defn dr-create [req] {:status 201 :body "created"})
(defn dr-users [req] {:status 200 :body "users"})

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

(def [sugar-home _] (router/match sugar-table :get "/"))
(assert (= :dr-home (sugar-home :name)) "a bare handler symbol names its route")
(assert (= 'dr-home (sugar-home :handler)) "and is quoted for late binding")
(assert (not (sugar-home :no-reload)) "so the route reloads with the module")
(assert (= 30 (get-in sugar-home [:meta :void.http/timeout]))
        "the leading dictionary is the global metadata layer")

(def [sugar-create _] (router/match sugar-table :post "/entries"))
(assert (= :entries/create (sugar-create :name)) "an explicit :name wins")
(assert (get-in sugar-create [:meta :app/flag]) "route metadata is kept")

(def [sugar-users _] (router/match sugar-table :get "/admin/users"))
(assert (= :dr-users (sugar-users :name)) "group children expand too")
(assert (get-in sugar-users [:meta :app/flag]) "under the group metadata layer")

(def [sugar-raw _] (router/match sugar-table :get "/raw"))
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
