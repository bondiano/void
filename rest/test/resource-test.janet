(import ../test-support/paths)
(import void/http/router :as router)
(import void/rest/resource :as resource)

(defn h [req] {:status 200})

# -- conventional actions ------------------------------------------------

(def orders
  (resource/resource :orders "/orders"
    {:id-schema :int}
    {:index {:handler h :query {:page [:optional :int]}
             :response {200 :any}}
     :show {:handler h :response {200 :any}}
     :create {:handler h :body {:title :string} :response {201 :any}}
     :destroy {:handler h :response {204 :nil}}
     :cancel {:method :post :path "/:id/cancel" :handler h}}))

(assert (orders :group))
(assert (= "/orders" (orders :prefix)))

(def by-name
  (tabseq [r :in (orders :children)] (get-in r [:meta :name]) r))

(assert (deep= (sorted (keys by-name))
               @[:orders/cancel :orders/create :orders/destroy
                 :orders/index :orders/show]))

# conventional method/path fill-in
(assert (= :get ((by-name :orders/index) :method)))
(assert (= "/" ((by-name :orders/index) :pattern)))
(assert (= :get ((by-name :orders/show) :method)))
(assert (= "/:id" ((by-name :orders/show) :pattern)))
(assert (= :post ((by-name :orders/create) :method)))
(assert (= :delete ((by-name :orders/destroy) :method)))
(assert (= :post ((by-name :orders/cancel) :method)))
(assert (= "/:id/cancel" ((by-name :orders/cancel) :pattern)))

# schemas land as :void.schema/* metadata
(assert (deep= {:page [:optional :int]}
               (get-in by-name [:orders/index :meta :void.schema/query])))
(assert (deep= {:title :string}
               (get-in by-name [:orders/create :meta :void.schema/body])))
(assert (deep= {201 :any}
               (get-in by-name [:orders/create :meta :void.schema/response])))

# :id-schema flows onto every /:id action without explicit params
(assert (deep= {:id :int}
               (get-in by-name [:orders/show :meta :void.schema/params])))
(assert (deep= {:id :int}
               (get-in by-name [:orders/cancel :meta :void.schema/params])))
(assert (nil? (get-in by-name [:orders/index :meta :void.schema/params])))

# -- the whole group builds into a route table ---------------------------

(def table
  (router/build-table
    {:sources [{:name :test :routes (router/routes {} orders)}]
     :meta-keys {:void.schema/params {} :void.schema/query {}
                 :void.schema/body {} :void.schema/headers {}
                 :void.schema/response {}}}))
(assert (= 5 (length (table :routes))))
(def [entry params] (router/match table :get "/orders/42"))
(assert (= :orders/show (entry :name)))
(assert (= "42" (params :id)))
(assert (= "/orders/7/cancel" (router/url-for table :orders/cancel {:id 7})))

# -- the two-argument form (no opts) and error cases ---------------------

(def bare (resource/resource :things "/things" {:index {:handler h}}))
(assert (= 1 (length (bare :children))))

(assert (not (first (protect (resource/resource :x "/x" {})))))
(assert (not (first (protect (resource/resource :x "/x" {:index {}})))))
(assert (not (first (protect (resource/resource :x "/x" {:frobnicate {:handler h}})))))
(assert (not (first (protect (resource/resource :x "/x" {:index {:handler h :whoops 1}})))))
(assert (not (first (protect (resource/resource :x "/x" {:bad-opt true} {:index {:handler h}})))))

# -- defresource sugar ---------------------------------------------------

(resource/defresource widgets "/widgets"
  {:show {:handler h :response {200 :any}}})
(assert (widgets :group))
(assert (= :widgets/show (get-in (first (widgets :children)) [:meta :name])))

(print "resource-test: ok")
