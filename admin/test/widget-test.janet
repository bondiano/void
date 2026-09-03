### The widget contract: one required function, five optional ones, and a
### resolution order that is printed rather than guessed at.
###
### The first half is pure — resolution is a function of a declaration,
### a field and a list of contributions, and it must be testable
### without a system, because that is what "resolved once at mount"
### means. The second half boots, because `:routes` and `:assets` are
### claims about the route table and the layout.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/test :as test)
(import void/db :as db)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/authz :as authz)
(import void/admin :as admin)
(import void/admin/widget :as widget)
(import void/admin/resource :as res)

(log/set-level! nil :error)

(db/defentity Brand
  {:id [:int {:db/pk true}]
   :name [:string {:min 1 :max 40}]}
  :db/table "brands")

(db/defentity Item
  {:id [:int {:db/pk true}]
   :brand-id [:int {:db/fk :Brand}]
   :name [:string {:min 1 :max 40}]
   :price [:int {:min 0}]
   :note [:optional :string]}
  :db/table "items"
  :db/rels {:brand [:belongs-to :Brand :brand-id]})

(def money
  "A contributed widget that claims a type."
  (widget/normalize
    {:name :money
     :types [:int]
     :priority 10
     :render (fn [ctx] [:input {:name (ctx :name) :value (string (or (ctx :value) 0))}])
     :display (fn [ctx] [:span (string (/ (or (ctx :value) 0) 100) " ₽")])
     :parse (fn [raw ctx] (math/round (* 100 (or (scan-number (string raw)) 0))))}))

(def loud
  "One that claims the same type, louder."
  (widget/normalize
    {:name :loud
     :match (fn [field] (= :price (field :name)))
     :priority 900
     :render (fn [ctx] [:b "loud"])}))

(def spelled
  (widget/normalize {:name :spelled :render (fn [ctx] [:i "spelled"])}))

# -- resolution order ----------------------------------------------------

(defn- why [desc fname contribs]
  (def entries (widget/resolve-all desc contribs))
  (def e (get entries fname))
  [(get-in e [:widget :name]) (e :why)])

(def plain (res/resource :items Item :form [:name :price :note :brand-id]))

(assert (deep= [:void.admin/form :schema] (why plain :name []))
        "a field the schema fully describes falls through to html/form")
(assert (deep= [:void.admin/link :relation] (why plain :brand-id []))
        "a foreign key is drawn by the link widget, because :db/rels said so")
(assert (deep= [:money :contributed] (why plain :price [money]))
        "a contribution that claims the type wins over the schema fallback")
(assert (deep= [:loud :contributed] (why plain :price [money loud]))
        "and the louder priority wins over the other contribution")

(def declared (res/resource :items Item :form [:price] :widgets {:price :spelled}))
(assert (deep= [:spelled :declared] (why declared :price [money loud spelled]))
        "a widget named on the field wins over every contribution")

(def anon (res/resource :items Item :form [:price]
                        :widgets {:price {:render (fn [ctx] [:span "here"])}}))
(assert (= :declared (get-in (widget/resolve-all anon []) [:price :why]))
        "an anonymous widget is declared where it is used")

(def [ok err]
  (protect (widget/resolve-all (res/resource :items Item :form [:price]
                                             :widgets {:price :nope})
                               [money])))
(assert (not ok))
(assert (string/find "nothing contributed" (string err))
        "a widget name nobody contributed is an error with the vocabulary in it")

# even a foreign key yields to a contribution that claims it — the link
# widget is a *fallback*, not a rule
(def claims-fk
  (widget/normalize {:name :fk-mine :match (fn [f] (= :brand-id (f :name)))
                     :render (fn [ctx] [:span "mine"])}))
(assert (deep= [:fk-mine :contributed] (why plain :brand-id [claims-fk])))

# -- the contract itself -------------------------------------------------

(defn- fails [f]
  (def [ok err] (protect (f)))
  (assert (not ok) "expected a refusal")
  (string err))

(assert (string/find ":render is required" (fails |(widget/normalize {:name :x}))))
(assert (string/find "unknown key" (fails |(widget/normalize {:name :x :render print :rendr 1}))))
(assert (string/find "must be a function"
                     (fails |(widget/normalize {:name :x :render print :parse 7}))))

# -- what the optional halves do -----------------------------------------

(def entries (widget/resolve-all plain [money]))

(assert (deep= [:span "12.34 ₽"]
               (widget/display (entries :price) {:mode :list :value 1234}))
        ":display draws the cell")
(assert (= 1234 (widget/parse (entries :price) "12.34" {}))
        ":parse turns what a form submitted into what the domain holds")

# without a :display, the cell is the text projection — and a long one is
# truncated, because a body column must not turn one row into a page
(def long (string/repeat "x" 200))
(def truncated (widget/display (entries :note) {:mode :list :value long}))
(assert (string/has-suffix? "…" truncated))
(assert (< (length truncated) (length long)))
(assert (= 200 (length (widget/display (entries :note) {:mode :detail :value long})))
        "...but the detail page shows the whole of it")
(assert (= "—" (widget/display (entries :note) {:mode :list :value nil}))
        "a blank cell and a missing column must not look the same")

# -- assets are glued once per widget, not once per control --------------

(def styled
  (widget/normalize {:name :styled :types [:int]
                     :assets {:style ".x{}"}
                     :render (fn [ctx] [:span])}))
(def two-int (res/resource :items Item :form [:price] :list [:price :id]))
(assert (= 1 (length (widget/assets (widget/resolve-all two-int [styled]))))
        "one entry per widget name, however many fields it draws")

# -- :routes: the seam FK autocompletion is the first user of ------------

(db/defentity Note {:id [:int {:db/pk true}] :title :string} :db/table "notes")

(plugin/contribute! :void.admin/widget
  {:name :test/with-route
   :match (fn [field] (= :title (field :name)))
   :render (fn [ctx] [:input {:name (ctx :name)}])
   :assets {:style ".from-widget{}"}
   :routes (fn [ctx]
             [(router/route :get "/suggest"
                            (fn [req] {:status 200 :headers @{} :body "suggested"}))])})

(admin/defresource-admin notes Note :form [:title] :list [:title])
(admin/defresource-admin brands Brand :list [:id :name])
(admin/defresource-admin items Item :form [:name :brand-id] :list [:id :name])
(authz/defpolicy :staff "Everybody, in this test." [_] true)

(def boot
  (test/start!
    {:plugins ["void/http/init" "void/html/init" "void/htmx/init"
               "void/db/init" "void/db-sqlite/init" "void/db/http"
               "void/authz/init" "void/authz/http" "void/admin/init"
               (plugin/manifest 'test/widgets :requires {:void/admin ">=0.0.1"})]
     :profile :test
     :config {:env @{} :cli {:http {:port 0}
                             :db-sqlite {:path ":memory:"}
                             :db {:pool {:size 1}}
                             :admin {:access :staff}}}
     :only [:http/kernel :db/pool :authz/registry]}))

(defer (test/stop! boot)
  (def table (http/routes-table))
  (def e (get-in table [:by-name :admin.notes/w-title-1]))
  (assert e "a widget's own route is mounted")
  (assert (= "/admin/notes/-/w/title/suggest" (e :pattern))
          "...under the resource, in the `-` namespace where no :id can reach it")
  (assert (index-of :void.admin/access (get-in e [:meta :void.authz/policy]))
          "...and behind the same gate as everything else")

  (def c (test/client boot))
  (assert (= "suggested" (test/text (test/inject c {:uri "/admin/notes/-/w/title/suggest"}))))

  # The widget's stylesheet reaches the page as a *file*, not as an
  # inline <style>: a composition that adds the back office must not
  # have to spend `'unsafe-inline'` on somebody else's markup.
  (def page (test/text (test/inject c {:uri "/admin/notes/new"})))
  (assert (not (string/find "<style" page))
          "nothing inline in the head — the sheet is served")
  (def href
    (first (peg/match ~(* (thru `<link rel="stylesheet" href="`) (<- (to `"`))) page)))
  (assert href "the frame links the served sheet")
  (assert (string/has-prefix? "/admin/-/assets/admin-" href)
          "...under the admin prefix, fingerprinted")
  (def sheet (test/inject c {:uri href}))
  (assert (= 200 (sheet :status)))
  (assert (string/find ".from-widget{}" (test/text sheet))
          "and the widget's :assets are in it")
  (assert (string/find "immutable" (get-in sheet [:headers "cache-control"]))
          "the URL carries the content's crc32, so the response never expires")
  (assert (string/has-prefix? "private" (get-in sheet [:headers "cache-control"]))
          "...and it is behind the admin's gate, so no shared cache keeps it")

  # -- the link widget picks its shape from the size of the target -------
  #
  # A belongs-to is drawn by one widget, and while the target is small
  # that shape is a select with the target's rows in it — labelled by
  # `label-of`, because a picker showing primary keys is a picker nobody
  # can use.
  (db/execute-sql "CREATE TABLE brands (id integer primary key autoincrement, name text not null)"
                  [] {:kind :write :prepared false})
  (db/execute-sql (string "CREATE TABLE items (id integer primary key autoincrement, "
                          "brand_id integer, name text not null, price integer not null, note text)")
                  [] {:kind :write :prepared false})
  (each n ["Acme" "Globex"]
    (db/execute-sql "INSERT INTO brands (name) VALUES (?)" [n] {:kind :write}))

  (def form (test/text (test/inject c {:uri "/admin/items/new"})))
  (assert (string/find "<select" form) "few rows in the target means a select")
  (assert (string/find "Acme" form) "and the options are labelled, not numbered")
  (assert (string/find "Globex" form)))

(print "admin widget-test ok")
