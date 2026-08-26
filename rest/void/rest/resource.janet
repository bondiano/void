### void/rest/resource — defresource: a REST resource as route data
### (SPEC.md §5.2, ADR-0004, ROADMAP 1.4).
###
### `resource` is an ordinary function producing an ordinary
### router/group — data first, the `defresource` macro is one line of
### sugar over it. A resource is a path prefix plus a table of actions;
### the conventional five (:index :show :create :update :destroy, plus
### :replace for PUT) get their method and path filled in, any other
### key is a custom action and states its own :method/:path. Each
### action's :params/:query/:body/:headers/:response schemas land on
### the route as the :void.schema/* metadata keys — the validation
### middleware and void/openapi read them from there; the action table
### IS the endpoint contract. Route names follow :<resource>/<action>
### (:orders/show), so url-for and metrics get stable names for free.

(import void/http/router :as router)

(def actions
  "The conventional actions: action -> {:method :path}."
  {:index {:method :get :path "/"}
   :show {:method :get :path "/:id"}
   :create {:method :post :path "/"}
   :update {:method :patch :path "/:id"}
   :replace {:method :put :path "/:id"}
   :destroy {:method :delete :path "/:id"}})

(def- schema-meta-keys
  {:params :void.schema/params
   :query :void.schema/query
   :body :void.schema/body
   :headers :void.schema/headers
   :response :void.schema/response})

(def- allowed-spec-keys
  (merge {:handler true :method true :path true :meta true}
         (tabseq [k :in (keys schema-meta-keys)] k true)))

(def- allowed-opt-keys
  {:id-schema true :meta true})

(defn- action-route [rname action spec id-schema]
  (unless (dictionary? spec)
    (errorf "resource %q action %q: expected an action table, got %q"
            rname action spec))
  (eachk k spec
    (unless (in allowed-spec-keys k)
      (errorf "resource %q action %q: unknown key %q" rname action k)))
  (def conv (get actions action))
  (def method (or (spec :method) (get conv :method)))
  (def path (or (spec :path) (get conv :path)))
  (unless (and method path)
    (errorf "resource %q: custom action %q needs :method and :path"
            rname action))
  (def handler
    (or (spec :handler)
        (errorf "resource %q action %q: :handler is required" rname action)))
  (def rmeta @{:name (keyword rname "/" action)})
  (eachp [k mk] schema-meta-keys
    (when-let [v (spec k)]
      (put rmeta mk v)))
  (when (and id-schema
             (string/find "/:id" path)
             (nil? (get rmeta :void.schema/params)))
    (put rmeta :void.schema/params {:id id-schema}))
  (merge-into rmeta (get spec :meta {}))
  (router/route method path handler rmeta))

(defn resource
  ``A REST resource as a router/group — drop it into a route source
  next to plain routes:

      (rest/resource :orders "/orders"
        {:id-schema :int}
        {:index   {:handler 'app.orders/index
                   :query ListQuery :response {200 :OrderList}}
         :show    {:handler 'app.orders/show :response {200 :Order}}
         :create  {:handler 'app.orders/create
                   :body :CreateOrder :response {201 :Order}}
         :destroy {:handler 'app.orders/destroy :response {204 :nil}}
         :cancel  {:method :post :path "/:id/cancel"
                   :handler 'app.orders/cancel :response {200 :Order}}})

  Conventional actions (see `actions`) get method and path filled in;
  a custom action states its own. Per action, :params/:query/:body/
  :headers/:response become the :void.schema/* route metadata (the
  validation middleware and void/openapi pick them up) and :meta merges
  any extra keys in. Routes are named :<resource>/<action>. opts:
  :id-schema puts {:id <schema>} params on every /:id action that
  declares none, :meta is the group metadata layer.``
  [rname prefix &opt opts specs]
  (unless (keyword? rname)
    (errorf "resource name must be a keyword, got %q" rname))
  # (resource :orders "/orders" {...actions}) — opts omitted
  (def [opts specs]
    (if (nil? specs)
      [{} opts]
      [(or opts {}) specs]))
  (unless (dictionary? specs)
    (errorf "resource %q: expected an action table, got %q" rname specs))
  (when (empty? specs)
    (errorf "resource %q has no actions" rname))
  (eachk k opts
    (unless (in allowed-opt-keys k)
      (errorf "resource %q: unknown option %q" rname k)))
  (router/group prefix (get opts :meta {})
                ;(seq [action :in (sorted (keys specs))]
                   (action-route rname action (specs action)
                                 (opts :id-schema)))))

(defmacro defresource
  ``Define `name` as a resource group (sugar over `resource`):

      (defresource orders "/orders"
        {:id-schema :int}
        {:show {:handler 'app.orders/show :response {200 :Order}}})``
  [name prefix & forms]
  ~(def ,name (,resource ,(keyword name) ,prefix ,;forms)))
