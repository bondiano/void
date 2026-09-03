### The declaration is a value: built from the entity, frozen, and
### readable by anybody. Everything below asserts on the descriptor alone
### — no system, no database, no routes — because a declaration that
### needed a running system to be inspected would be a declaration the MCP
### projection could not read either.

(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/db :as db)
(import void/admin/resource :as res)

(db/defentity Widget
  {:id [:int {:db/pk true}]
   :brand-id [:int {:db/fk :Brand}]
   :name [:string {:min 1 :max 60}]
   :kind [:enum :simple :complex]
   :price [:int {:min 0}]
   :published :boolean
   :lock [:optional [:int {:db/version true}]]
   :note [:optional :string]}
  :db/table "widgets"
  :db/rels {:brand [:belongs-to :Brand :brand-id]
            :parts [:has-many :Part :widget-id]})

(db/defentity Brand
  {:id [:int {:db/pk true}]
   :name [:string {:min 1 :max 60}]}
  :db/table "brands"
  :db/rels {:widgets [:has-many :Widget :brand-id]})

(db/defentity Part
  {:id [:int {:db/pk true}]
   :widget-id [:int {:db/fk :Widget}]
   :label [:string {:min 1 :max 60}]}
  :db/table "parts"
  :db/rels {:widget [:belongs-to :Widget :widget-id]})

# -- defaults ------------------------------------------------------------

(def d (res/resource :widgets Widget))

(assert (= :widgets (d :name)))
(assert (= "/widgets" (d :path)))
(assert (d :mount))
(assert (deep= (tuple ;res/standard-actions) (d :actions)))

# the form is every writable field: no primary key, no version column —
# neither is something an operator types
(assert (nil? (index-of :id (d :form))))
(assert (nil? (index-of :lock (d :form))))
(assert (index-of :name (d :form)))

# the form schema is a *projection* of the entity, not a copy of it
(def checked (schema/check (d :form-schema)
                           {:name "" :kind :simple :price 1 :published true
                            :brand-id 1 :note nil}))
(assert (not (empty? (checked :errors)))
        "the entity's own :min 1 on :name is the form's, because it is the same node")

# -- field descriptors ---------------------------------------------------

(def name-field (first (filter |(= :name ($ :name)) (d :form-fields))))
(assert (= :string (name-field :type)))
(assert (name-field :required))
(assert (= "Name" (name-field :label)))

(def note-field (first (filter |(= :note ($ :name)) (d :form-fields))))
(assert (not (note-field :required)) "an :optional field is not required")

(def fk-field (first (filter |(= :brand-id ($ :name)) (d :form-fields))))
(assert (= :belongs-to (get-in fk-field [:rel :kind]))
        "the foreign key knows its relation, and it learned it from :db/rels")

# -- explicit options ----------------------------------------------------

(def e (res/resource :widgets Widget
                     :title "Gadgets"
                     :path "/gadgets"
                     :mount false
                     :only [:index :show]
                     :list [:id :name {:name :summary :label "Summary"
                                       :value (fn [row] "x")}]
                     :form [:name :price]
                     :readonly [:price]
                     :filters [:published {:field :kind :label "Type"}]
                     :search [:name]
                     :sortable [:name]
                     :editable [:name]
                     :preload [:brand]
                     :inlines {:parts {:style :table :fields [:label]}}))

(assert (= "Gadgets" (e :title)))
(assert (= "/gadgets" (e :path)))
(assert (not (e :mount)))
(assert (deep= [:index :show] (e :actions)))
(assert (= 3 (length (e :list))))
(assert (nil? (get-in e [:list 2 :field])) "a computed column has no entity field")

# :readonly is not merely "not drawn": it is out of the schema the form
# validates against, so a forged field cannot reach save!
(assert (deep= [:name] (tuple ;(map |($ 0) (get-in e [:form-schema :children])))))

(assert (= 2 (length (e :filters))))
(assert (= "Type" (get-in e [:filters 1 :label])))
(assert (= :has-many (get-in e [:inlines :parts :rel :kind])))
(assert (= :parts (get-in e [:inlines :parts :resource])))

# -- refusals ------------------------------------------------------------

(defn- fails [f msg]
  (def [ok err] (protect (f)))
  (assert (not ok) (string "expected a refusal: " msg))
  (string err))

(assert (string/find "unknown option"
                     (fails |(res/resource :widgets Widget :listt [:id]) "a typo in an option")))

(assert (string/find "has no field"
                     (fails |(res/resource :widgets Widget :list [:nope])
                            "a list column that is not a field")))

(assert (string/find "two answers to one question"
                     (fails |(res/resource :widgets Widget :only [:index] :except [:show])
                            ":only and :except together")))

(assert (string/find "is not a relation"
                     (fails |(res/resource :widgets Widget :inlines {:nope {}})
                            "an inline over a relation that does not exist")))

(assert (string/find "belongs-to"
                     (fails |(res/resource :widgets Widget :inlines {:brand {}})
                            "an inline over a belongs-to")))

(assert (string/find "conventional actions"
                     (fails |(res/resource :widgets Widget :actions {:destroy {:apply (fn [r q] nil)}})
                            "redeclaring one of the seven")))

(assert (string/find "a button that lies"
                     (fails |(res/resource :widgets Widget :actions {:publish {:label "Publish"}})
                            "an action with nothing to do")))

# -- names ---------------------------------------------------------------

(assert (= :admin.widgets/destroy (res/policy-name :widgets :destroy)))
(assert (= (res/policy-name :widgets :destroy) (res/route-name :widgets :destroy))
        "the policy and the route are one name, which is why `void routes` and `void authz routes` read as one listing")

# -- the registry --------------------------------------------------------

(res/register! d)
(res/register! (res/resource :brands Brand))
(res/register! (res/resource :parts Part :mount false))

(assert (deep= @[:brands :parts :widgets] (res/resources)))
(assert (deep= @[:brands :widgets] (res/mounted)) ":mount false leaves the declaration without a section")
(assert (= :widgets ((res/lookup :widgets) :name)))
(assert (string/find "unknown admin resource" (fails |(res/resource! :nope) "an unknown resource")))

# re-declaring replaces, which is what makes a REPL redefinition take
# effect
(res/register! (res/resource :widgets Widget :title "Again"))
(assert (= "Again" ((res/lookup :widgets) :title)))

(print "admin resource-test ok")
