### void/admin/resource — the declaration, as a frozen value
### (SPEC.md §5.21, ADR-0029 §1).
###
### `resource` builds a descriptor out of an entity plus options;
### `defresource-admin` is one line of sugar over it (ADR-0004). The
### descriptor is the *only* declaration: `./mount` projects it into
### routes, `./mcp` projects the same value into MCP tools and
### resources, and both read the same policy names. A second
### declaration for the agent is a declaration that will drift, so
### there is not one.
###
### Everything the descriptor knows about the domain it read from
### somewhere that already knew it: columns, primary key, version
### column and relations come from the entity descriptor (ADR-0009),
### types and bounds from the schema node (ADR-0008). What the
### declaration adds is what a schema cannot say — which fields belong
### in a list, which are searched, which are filtered, who the rows
### belong to.
###
### The form schema is a **projection**, not a copy:
### `(schema/select entity form-fields)`, so the validation of the
### form and the input schema of the MCP tool are literally one value.

(import void/core/schema :as schema)
(import void/db/entity :as entity)

# -- actions -------------------------------------------------------------

(def standard-actions
  ``The seven conventional actions, in the order a reader expects them
  and in the order their routes must be emitted: a literal segment has
  to be tried before `:id` swallows it.``
  [:index :new :create :show :edit :update :destroy])

(def read-actions
  "The actions that only read — what the MCP projection may expose
  without an operator naming it (ADR-0031's gate, asked here)."
  {:index true :show true})

(def- standard-set (tabseq [a :in standard-actions] a true))

(defn policy-name
  ``The policy every route of one action carries besides the gate:
  `:admin.articles/destroy`. It exists so that "only the owner may
  delete" has a name already written on the route — the application
  narrows the action by defining a policy under this name and touches
  neither the declaration nor the routes (ADR-0029 §3).``
  [rname action]
  (keyword "admin." rname "/" action))

(defn route-name
  "The route name of one action of one resource — the same string the
  policy carries, which is why `void routes` and `void authz routes`
  read as one listing."
  [rname action]
  (policy-name rname action))

# -- option checking -----------------------------------------------------

(def- allowed-opts
  {:title true :singular true :path true :mount true
   :only true :except true :actions true
   :list true :form true :readonly true :detail true
   :filters true :search true :sortable true :editable true
   :order-by true :per-page true :preload true
   :scope true :widgets true :inlines true :doc true :defaults true})

(defn- check-opts [rname opts]
  (eachk k opts
    (unless (in allowed-opts k)
      (errorf "admin resource %q: unknown option %q (allowed: %s)"
              rname k
              (string/join (map |(string/format "%q" $) (sorted (keys allowed-opts))) " ")))))

(defn- humanize [k]
  (def s (string/replace-all "-" " " (string k)))
  (if (empty? s)
    s
    (string (string/ascii-upper (string/slice s 0 1)) (string/slice s 1))))

(defn- titleize [k]
  (humanize k))

(defn- known-fields [ent]
  (string/join (map |(string/format "%q" $) (ent :field-order)) " "))

(defn- check-field [rname ent where k]
  (unless (get-in ent [:fields k])
    (errorf "admin resource %q: %s names %q, which %q has no field for (fields: %s)"
            rname where k (ent :name) (known-fields ent)))
  k)

# -- field descriptors ---------------------------------------------------
#
# One value per field, carrying everything a widget is allowed to ask
# about the field it is drawing: the schema node with its wrappers
# stripped, whether the wrapper was :optional, the :db/* annotations
# the entity layer already parsed, and the relation this column is the
# foreign key of. A widget that had to re-derive any of this would be
# re-deriving it per render.

(defn- unwrap
  "Strip :optional/:ref wrappers -> [inner-node required?]."
  [node]
  (case (node :type)
    :optional (let [[inner _] (unwrap (first (node :children)))] [inner false])
    :ref (let [name (get-in node [:props :name])]
           (unwrap (or (schema/lookup name)
                       (errorf "schema %q is not registered" name))))
    [node true]))

(defn- fk-relation
  "The belongs-to relation whose key is this field, or nil — a column
  is drawn as a link picker because the *entity* says it points
  somewhere, never because the admin declared a second time that it
  does (ADR-0029 §5)."
  [ent fname]
  (var out nil)
  (eachp [_ rel] (ent :rels)
    (when (and (nil? out)
               (= :belongs-to (rel :kind))
               (= fname (rel :key)))
      (set out rel)))
  out)

(defn field-descriptor
  ``What a widget is handed as `:field`: the name, the label, whether
  the schema made it required, the unwrapped schema node, the :db/*
  annotations and the relation this column is the foreign key of.``
  [ent fname]
  (def f (or (get-in ent [:fields fname])
             (errorf "%q has no field %q (fields: %s)" (ent :name) fname (known-fields ent))))
  (def child (get-in ent [:schema :children]))
  (def node
    (or (first (seq [[k sub] :in child :when (= k fname)] sub))
        (errorf "%q: field %q is not in its schema" (ent :name) fname)))
  (def [inner required?] (unwrap node))
  (freeze
    {:name fname
     :label (humanize fname)
     :required required?
     :node inner
     # the child as the schema declared it, :optional wrapper and all —
     # what html/form is handed, so the fallback control is projected by
     # the code that already knows how, not by a copy of it
     :schema node
     :type (inner :type)
     :column (f :column)
     :db (freeze (tabseq [[k v] :pairs f
                          :when (and (keyword? k) (string/has-prefix? "db/" k))]
                   k v))
     :pk (= fname (ent :pk))
     :version (= fname (ent :version))
     :rel (fk-relation ent fname)}))

# -- list columns --------------------------------------------------------

(defn- list-column [rname ent spec]
  (cond
    (keyword? spec)
    (freeze {:name spec :label (humanize spec)
             :field (field-descriptor ent (check-field rname ent ":list" spec))})

    (dictionary? spec)
    (do
      (def name (or (get spec :name)
                    (errorf "admin resource %q: a :list column table needs a :name" rname)))
      (def value (get spec :value))
      (unless (or value (get-in ent [:fields name]))
        (errorf (string "admin resource %q: :list column %q is not a field of %q and "
                        "carries no :value function (fields: %s)")
                rname name (ent :name) (known-fields ent)))
      (freeze (merge {:label (humanize name)}
                     spec
                     {:name name
                      :field (when (get-in ent [:fields name])
                               (field-descriptor ent name))})))

    (errorf "admin resource %q: a :list column is a field keyword or a table, got %q"
            rname spec)))

# -- filters -------------------------------------------------------------

(defn- filter-spec [rname ent spec]
  (def base
    (cond
      (keyword? spec) {:field spec}
      (dictionary? spec) spec
      (errorf "admin resource %q: a :filter is a field keyword or a table, got %q" rname spec)))
  (def fname (or (get base :field)
                 (errorf "admin resource %q: a :filters table needs a :field" rname)))
  (check-field rname ent ":filters" fname)
  (def fd (field-descriptor ent fname))
  # the declaration's :field names the column; the descriptor's :field
  # *is* the column, so it goes on last
  (freeze (merge {:label (fd :label) :param (string fname)}
                 base
                 {:name fname :field fd})))

# -- inlines -------------------------------------------------------------

(def- allowed-inline-keys
  {:style true :fields true :per-page true :order-by true
   :can-add true :can-delete true :label true :resource true})

(defn- inline-spec [rname ent iname spec]
  (unless (dictionary? spec)
    (errorf "admin resource %q: inline %q must be a table, got %q" rname iname spec))
  (eachk k spec
    (unless (in allowed-inline-keys k)
      (errorf "admin resource %q: inline %q: unknown key %q (allowed: %s)"
              rname iname k
              (string/join (map |(string/format "%q" $) (sorted (keys allowed-inline-keys))) " "))))
  (def rel
    (or (get-in ent [:rels iname])
        (errorf (string "admin resource %q: inline %q is not a relation of %q "
                        "(relations: %s) — an inline is a projection of :db/rels, "
                        "never a second declaration of the link (ADR-0029 §5)")
                rname iname (ent :name)
                (string/join (map |(string/format "%q" $) (sorted (keys (ent :rels)))) " "))))
  (unless (in {:has-many true :has-one true} (rel :kind))
    (errorf (string "admin resource %q: inline %q is a %q relation — an inline edits "
                    "the rows that belong to this one, so it needs :has-many or :has-one; "
                    "a :belongs-to is drawn by the link widget instead")
            rname iname (rel :kind)))
  (def style (get spec :style :table))
  (unless (in {:table true :stacked true} style)
    (errorf "admin resource %q: inline %q: :style is :table or :stacked, got %q"
            rname iname style))
  (freeze (merge {:name iname
                  :label (humanize iname)
                  :style style
                  :per-page 10
                  :can-add true
                  :can-delete true
                  # the child resource in the registry; often :mount false,
                  # so its fields, widgets and policies are declared once
                  :resource iname
                  :rel rel}
                 spec)))

# -- custom actions ------------------------------------------------------

(def- allowed-action-keys
  {:label true :doc true :apply true :job true :progress true
   :read-only? true :confirm true :danger true :needs-selection true})

(defn- action-spec [rname aname spec]
  (unless (dictionary? spec)
    (errorf "admin resource %q: action %q must be a table, got %q" rname aname spec))
  (when (in standard-set aname)
    (errorf (string "admin resource %q: %q is one of the seven conventional actions "
                    "(%s) — narrow it with a policy named %q, do not redeclare it")
            rname aname
            (string/join (map string standard-actions) " ")
            (policy-name rname aname)))
  (eachk k spec
    (unless (in allowed-action-keys k)
      (errorf "admin resource %q: action %q: unknown key %q (allowed: %s)"
              rname aname k
              (string/join (map |(string/format "%q" $) (sorted (keys allowed-action-keys))) " "))))
  (unless (or (get spec :apply) (get spec :job))
    (errorf (string "admin resource %q: action %q needs an :apply (fn [row request]) "
                    "or a :job — an action that does nothing is a button that lies")
            rname aname))
  (freeze (merge {:name aname
                  :label (humanize aname)
                  :needs-selection true
                  :danger false}
                 spec)))

# -- the descriptor ------------------------------------------------------

(defn- enabled-actions [rname opts]
  (when (and (get opts :only) (get opts :except))
    (errorf "admin resource %q: :only and :except are two answers to one question" rname))
  (defn check [where names]
    (each a names
      (unless (in standard-set a)
        (errorf "admin resource %q: %s names %q, which is not one of %s"
                rname where a (string/join (map string standard-actions) " "))))
    names)
  (cond
    (get opts :only)
    (let [wanted (tabseq [a :in (check ":only" (opts :only))] a true)]
      (tuple ;(filter |(in wanted $) standard-actions)))
    (get opts :except)
    (let [gone (tabseq [a :in (check ":except" (opts :except))] a true)]
      (tuple ;(filter |(not (in gone $)) standard-actions)))
    (tuple ;standard-actions)))

(defn resource
  ``Build an admin resource descriptor — a frozen value, the single
  declaration `./mount` and `./mcp` both project:

      (admin/resource :articles Article
        :list     [:id :title :published]
        :search   [:title :body]
        :filters  [:published :author-id]
        :sortable [:id :title]
        :form     [:title :body :published]
        :preload  [:author]
        :inlines  {:comments {:style :table :fields [:body]}}
        :scope    (fn [req] [:= :brand-id (brand-of req)]))

  `entity` is anything `db/entity/resolve` accepts. Options:

  :title :singular  labels; :path  the URL segment (default "/<name>")
  :mount            false leaves the declaration without top-level
                    routes — the shape an inline target or an
                    agent-only resource has
  :only :except     which of the seven conventional actions exist
  :actions          extra actions, each a confirmation page
  :list             list columns: field keywords, or tables with a
                    :value (fn [row])
  :form             the fields of the create/edit form — the form
                    schema is (schema/select entity these)
  :readonly         fields shown but never written
  :detail           the fields of the detail page (default: all)
  :filters :search :sortable :editable   the list's four affordances
  :order-by :per-page :preload           the list query
  :scope            (fn [request] where) narrowing every read *and*
                    every count, so pagination counts what it shows
  :defaults         {field (fn [request] value)} — columns the server
                    fills on create because the form does not carry
                    them (a created-at, an owner). This is where
                    Django's auto_now_add goes: entities have no
                    callbacks by design (ADR-0009), so the value is
                    supplied by whoever writes the row, and the admin
                    is one of the writers
  :widgets          {field widget} overriding widget resolution
  :inlines          {relation {...}} — has-many/has-one edited in place``
  [rname ent & kvs]
  (unless (keyword? rname)
    (errorf "admin resource name must be a keyword, got %q" rname))
  (when (odd? (length kvs))
    (errorf "admin resource %q: expected key-value option pairs" rname))
  (def opts (table ;kvs))
  (check-opts rname opts)
  (def e (entity/resolve ent))
  (def actions (enabled-actions rname opts))
  (def writable
    (tuple ;(filter |(and (not= $ (e :pk)) (not= $ (e :version))) (e :field-order))))
  (def form-fields
    (tuple ;(map |(check-field rname e ":form" $) (get opts :form writable))))
  (def readonly (tuple ;(map |(check-field rname e ":readonly" $) (get opts :readonly []))))
  (def readonly-set (tabseq [k :in readonly] k true))
  (def custom
    (freeze (tabseq [[k v] :pairs (get opts :actions {})] k (action-spec rname k v))))
  (def defaults
    (freeze (tabseq [[k v] :pairs (get opts :defaults {})]
              (check-field rname e ":defaults" k)
              (if (function? v)
                v
                (errorf (string "admin resource %q: :defaults %q must be "
                                "(fn [request] value), got %q")
                        rname k v)))))
  (freeze
    {:name rname
     :doc (get opts :doc)
     :entity e
     :title (get opts :title (titleize rname))
     :singular (get opts :singular (titleize (e :name)))
     :path (get opts :path (string "/" rname))
     :mount (not= false (get opts :mount true))
     :actions actions
     :action-set (freeze (tabseq [a :in actions] a true))
     :custom-actions custom
     :list (tuple ;(map |(list-column rname e $) (get opts :list (e :field-order))))
     :detail (tuple ;(map |(check-field rname e ":detail" $) (get opts :detail (e :field-order))))
     :form form-fields
     # the form's validation schema and the MCP tool's input schema are
     # this one value (ADR-0029 §1); the fields the declaration froze as
     # read-only are not in it, so a forged field cannot reach `save!`
     :form-schema (schema/select (e :schema)
                                 (filter |(not (in readonly-set $)) form-fields))
     :form-fields (tuple ;(map |(field-descriptor e $) form-fields))
     :readonly readonly
     :filters (tuple ;(map |(filter-spec rname e $) (get opts :filters [])))
     :search (tuple ;(map |(check-field rname e ":search" $) (get opts :search [])))
     :sortable (tuple ;(map |(check-field rname e ":sortable" $) (get opts :sortable [])))
     :editable (tuple ;(map |(check-field rname e ":editable" $) (get opts :editable [])))
     :order-by (get opts :order-by [[(e :pk) :desc]])
     :per-page (get opts :per-page nil)
     :preload (get opts :preload nil)
     :scope (get opts :scope nil)
     :defaults defaults
     :widgets (freeze (get opts :widgets {}))
     :inlines (freeze (tabseq [[k v] :pairs (get opts :inlines {})]
                        k (inline-spec rname e k v)))}))

# -- the registry --------------------------------------------------------
#
# Global mutable process state, like the schema, entity and policy
# registries before it (ADR-0029, "Цена"). Re-declaring replaces, which
# is what makes a REPL redefinition take effect (ADR-0002).

(def- registry @{})

(defn register!
  "Register (or replace) a descriptor. Returns it."
  [desc]
  (put registry (desc :name) desc)
  desc)

(defn deregister!
  "Forget a resource."
  [rname]
  (put registry rname nil)
  nil)

(defn resources
  "Every declared resource name, sorted — what `void admin resources`
  prints and what both projections iterate."
  []
  (sorted (keys registry)))

(defn lookup
  "One descriptor by name, or nil."
  [rname]
  (get registry rname))

(defn resource!
  "One descriptor by name, or an error naming what is declared."
  [rname]
  (or (get registry rname)
      (errorf "unknown admin resource %q (declared: %s)"
              rname
              (string/join (map |(string/format "%q" $) (resources)) " "))))

(defn mounted
  "The resources that get top-level routes — the whole registry minus
  the ones declared with :mount false."
  []
  (filter |((lookup $) :mount) (resources)))

(defn define!
  "Build, register and return a descriptor — the runtime half of
  `defresource-admin`, so there is one implementation."
  [rname ent kvs]
  (register! (resource rname ent ;kvs)))

(defmacro defresource-admin
  ``Declare an admin resource (sugar over `resource` + `register!`):

      (defresource-admin articles Article
        :list   [:id :title]
        :search [:title]
        :form   [:title :body])

  The binding is the descriptor. The routes are not written here and
  not written by the application: `void/admin` projects the whole
  registry when the route table is built, and `void/admin-mcp`
  projects the same registry into tools and resources.``
  [name ent & kvs]
  ~(def ,name (,define! ,(keyword name) ,ent [,;kvs])))
