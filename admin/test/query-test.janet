### The state of a list is read out of the URL and turned into one
### where-clause (ADR-0029 §6, §10). Two properties matter more than
### the rest, and both are about what the clause is built *from*:
###
### The clause is built from the entity's own columns and the
### resource's own declarations — never from the keys a browser sent.
### A parameter names a declared filter, a declared search or a
### declared sortable column, or it does not reach SQL at all.
###
### And `query` and `count` are handed the *same* clause. A count that
### ignored the scope would page over rows nobody may see; a scope
### applied after loading would page over rows it then threw away.

(import ../test-support/paths)
(import void/db :as db)
(import void/db/builder :as builder)
(import void/admin/query :as q)
(import void/admin/resource :as res)

(db/defentity Post
  {:id [:int {:db/pk true}]
   :owner-id [:int {:db/fk :Author}]
   :title [:string {:min 1 :max 60}]
   :body [:optional :string]
   :state [:enum :draft :live]
   :views [:int {:min 0}]
   :done :boolean}
  :db/table "posts")

(def desc
  (res/resource :posts Post
                :list [:id :title]
                :search [:title :body]
                :filters [:state :done {:field :views}]
                :sortable [:id :views]
                :order-by [[:id :desc]]
                :per-page 10
                :scope (fn [req] [:= :owner-id (get-in req [:query "who"] 7)])))

(defn- req [query]
  @{:method :get :path "/admin/posts"
    :query (tabseq [[k v] :pairs query] k (string v))
    :params @{}})

(defn- sql [clause]
  (when clause
    (def [text params] (builder/format {:select [:id] :from "posts" :where clause}))
    [text params]))

# -- what the URL is allowed to say --------------------------------------

(def st (q/state desc (req {"page" "3" "sort" "views" "dir" "asc" "q" "hi"
                            "state" "live" "done" "false"})))
(assert (= 3 (st :page)))
(assert (= 10 (st :per-page)) ":per-page comes from the declaration, not the URL")
(assert (= 20 (st :offset)))
(assert (= :views (st :sort)))
(assert (= :asc (st :dir)))
(assert (= "hi" (st :q)))
(assert (= :live (get-in st [:filters :state :eq])) "an enum filter is coerced through the schema")
(assert (= false (get-in st [:filters :done :eq])) "and a boolean has three states, not two")

(def ignored (q/state desc (req {"sort" "body" "page" "-4" "state" "nonsense"})))
(assert (nil? (ignored :sort)) "a column that is not :sortable never reaches ORDER BY")
(assert (= 1 (ignored :page)) "a negative page is page one, not an offset backwards")
(assert (nil? (get-in ignored [:filters :state]))
        "a value outside the enum is no filter — not an error, and not a guess")

(def ranged (q/state desc (req {"views-from" "10" "views-to" "20"})))
(assert (= 10 (get-in ranged [:filters :views :from])))
(assert (= 20 (get-in ranged [:filters :views :to])))

# -- the clause ----------------------------------------------------------

(def [text params] (sql (q/where desc (req {}) (q/state desc (req {})))))
(assert (= "SELECT \"id\" FROM \"posts\" WHERE \"owner_id\" = ?" text)
        "with nothing asked for, the clause is the scope alone")
(assert (deep= [7] params) "and the value is a parameter, never interpolated")

(def full-state (q/state desc (req {"q" "ha" "state" "live" "views-from" "5"})))
(def [text2 params2] (sql (q/where desc (req {}) full-state)))
(assert (string/find "owner_id" text2) "the scope is always in it")
(assert (string/find "LIKE" text2) "the search is a LIKE over the declared columns")
(assert (string/find "\"body\"" text2) "...over every one of them")
(assert (string/find ">=" text2) "a range filter is two comparisons")
(assert (truthy? (index-of "%ha%" params2)))

# the ordering is the declared default until the URL names a sortable
# column — and then it is that column, by *its* column name
(assert (deep= [[:id :desc]] (q/order-by desc (q/state desc (req {})))))
(assert (deep= [[:views :asc]]
               (q/order-by desc (q/state desc (req {"sort" "views" "dir" "asc"})))))

# -- selections ----------------------------------------------------------

(def picked (q/selection desc (req {"ids" "1,2,3"}) (q/state desc (req {}))))
(assert (deep= [1 2 3] (picked :ids)) "identifiers are coerced through the primary key's type")
(def [ptext _] (sql (picked :where)))
(assert (string/find "IN" ptext))
(assert (string/find "owner_id" ptext)
        "a selection is intersected with the scope — a forged identifier picks nothing")

(def none (q/selection desc (req {"ids" ""}) (q/state desc (req {}))))
(def [ntext _] (sql (none :where)))
(assert (string/find "1 = 0" ntext) "nothing selected must select nothing, not everything")

(def everything (q/selection desc (req {"all" "1" "state" "live"})
                             (q/state desc (req {"state" "live"}))))
(assert (everything :all))
(def [etext eparams] (sql (everything :where)))
(assert (string/find "owner_id" etext))
(assert (string/find "\"state\"" etext)
        "\"every row the filter matches\" is the filter, recompiled here — the client sends no count")

# a form sends the same name several times; a link sends one comma-joined
# value. They are one selection
(def repeated (q/selection desc @{:query @{"ids" @["1" "2"]} :params @{}}
                           (q/state desc (req {}))))
(assert (deep= [1 2] (repeated :ids)))

# -- the primary key is coerced, never interpolated ----------------------

(assert (= 42 (q/pk-value desc "42")))
(assert (nil? (q/pk-value desc "42; DROP TABLE posts"))
        "a path parameter that is not of the key's type is nil, and a nil key loads nothing")

(print "admin query-test ok")
