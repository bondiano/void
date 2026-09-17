### void/db/entity — Data Mapper core with thin AR sugar.
###
### `defentity` is defschema plus db-mapping: one declaration feeds
### validation, the repository, preload planning, migrations-diff,
### void/admin and `void db erd`. The defined binding *is* the
### normalized schema — (schema/select User [:email]) projects a DTO
### straight off an entity — while the mapping (table, primary key,
### columns, relations) lives in a descriptor registered under the same
### name.
###
### Entities are plain data. A loaded row is an ordinary table whose
### prototype carries the descriptor, the load-time snapshot and the
### preloaded relations: `pp` prints the columns and nothing else, `keys`
### lists the columns, `put`/`merge` are how you change a record. `save!`
### diffs the table against its snapshot and writes only the changed
### columns; there is no lazy loading, no Unit of Work, and deliberately
### no lifecycle callbacks (audit and domain events belong in the outbox).
###
### N+1 is a bug the layer refuses to hide: `rel` on a relation nobody
### preloaded warns with the call site in dev and throws under
### :strict. The fix it names is always the same — declare :preload.

(import void/core/schema :as schema)
(import void/core/log :as log)
(import void/core/errors :as errors)
(import ./builder :as builder)
(import ./state :as state)
(import void/core/util :as util)

# -- descriptors ---------------------------------------------------------

(def entity-key
  "Schema prop holding the entity name — the bridge from a schema node
  back to its descriptor."
  :void.db/entity)

(def- registry @{})

(def- rel-kinds {:belongs-to true :has-many true :has-one true})

(defn- through-spec
  {:params [:keyword :keyword :any] :ret {:entity :keyword :key :keyword} :throws [:string]}
  ``The middle of a through-relation: {:entity :PostTag :key :tag-id} —
  the entity the rows are joined through and the field on it that
  points at the target. The relation's own `:key` keeps its meaning
  (the field on the other side that points back at us), so the two
  read as one sentence: a Post has many Tags through PostTag, whose
  :post-id points here and whose :tag-id points there.``
  [ename rname form]
  (unless (dictionary? form)
    (errorf "entity %q: relation %q :through must be {:entity :Name :key :field}, got %q"
            ename rname form))
  (unless (keyword? (get form :entity))
    (errorf "entity %q: relation %q :through must name an entity keyword, got %q"
            ename rname (get form :entity)))
  (unless (keyword? (get form :key))
    (errorf "entity %q: relation %q :through must name the key that points at the target, got %q"
            ename rname (get form :key)))
  (freeze {:entity (form :entity) :key (form :key)}))

(defn- rel-spec
  {:params [:keyword :keyword :any]
   :ret {:name :keyword :kind :keyword :entity :keyword :key :keyword
         :through (or {:entity :keyword :key :keyword} :nil) & r}
   :throws [:string]}
  ``Normalize one relation declaration — a `[kind :Entity :key]` tuple
  or a `{:kind ... :entity ... :key ...}` map, optionally with
  `:through` — into its full record, validating the kind and refusing
  a `:belongs-to :through` (a row pointing at one other row never
  needs a middle).``
  [ename rname form]
  (def spec
    (cond
      (dictionary? form) form
      (indexed? form)
      (do (unless (= 3 (length form))
            (errorf "entity %q: relation %q must be [kind :Entity :key], got %q"
                    ename rname form))
          {:kind (form 0) :entity (form 1) :key (form 2)})
      (errorf "entity %q: relation %q must be a tuple or a map, got %q"
              ename rname form)))
  (def kind (get spec :kind))
  (unless (in rel-kinds kind)
    (errorf "entity %q: relation %q has unknown kind %q (expected %s)"
            ename rname kind
            (util/names-str (keys rel-kinds))))
  (unless (keyword? (get spec :entity))
    (errorf "entity %q: relation %q must name a target entity keyword, got %q"
            ename rname (get spec :entity)))
  (unless (keyword? (get spec :key))
    (errorf "entity %q: relation %q must name a key field, got %q"
            ename rname (get spec :key)))
  (def through (when-let [t (get spec :through)] (through-spec ename rname t)))
  (when (and through (= :belongs-to kind))
    (errorf (string "entity %q: relation %q is :belongs-to :through — a row that "
                    "points at one other row does not need a middle; declare the "
                    "relation on the other side, or make it :has-one")
            ename rname))
  (freeze (merge @{:name rname} spec (if through {:through through} {}))))

(defn- field-map
  {:params [{:type :keyword :props {:any :any} :children [:any]} :keyword]
   :ret [{:keyword {:name :keyword :column :string :optional :boolean & r}} {:keyword :any}]
   :throws [:string]}
  ``The entity's fields — name, column, whether they are optional, plus
  every `:db/*` prop — built from a normalized map schema's children,
  paired with the schema's own top-level `:db/*` annotations.``
  [node ename]
  (unless (= :map (node :type))
    (errorf "entity %q: the schema must be a map schema, got %q" ename (node :type)))
  (def ann (schema/db-annotations node))
  (def out @{})
  (each [k sub] (node :children)
    (def props (get-in ann [:fields k] {}))
    (put out k
         (freeze (merge @{:name k
                          :column (get props :db/column (builder/snake k))
                          :optional (= :optional (sub :type))}
                        props))))
  [(freeze out) (ann :schema)])

(defn descriptor
  {:params [:keyword :any :any]
   :ret {:name :keyword
         :table :string
         :schema {:type :keyword :props {:any :any} :children [:any]}
         :pk :keyword
         :pk-column :string
         :version (or :keyword :nil)
         :fields {:keyword {:name :keyword :column :string :optional :boolean & r}}
         :columns [:string]
         :field-order [:keyword]
         :column->field {:keyword :keyword}
         :rels {:keyword {:name :keyword :kind :keyword :entity :keyword :key :keyword
                          :through (or {:entity :keyword :key :keyword} :nil) & r}}}
   :throws [:string]}
  ``Build an entity descriptor from a schema form plus db-mapping
  options (:db/table, :db/rels). `defentity` is the sugar; the
  descriptor is a frozen value you can pp, diff and project.``
  [name form & kvs]
  (unless (keyword? name)
    (errorf "entity name must be a keyword, got %q" name))
  (when (odd? (length kvs))
    (errorf "entity %q: expected key-value option pairs" name))
  (def opts (table ;kvs))
  (def node (schema/normalize form))
  (def [fields schema-ann] (field-map node name))
  (def table-name
    (or (get opts :db/table) (get schema-ann :db/table)
        (errorf "entity %q: :db/table is required" name)))
  (unless (string? table-name)
    (errorf "entity %q: :db/table must be a string, got %q" name table-name))
  (def pks (filter |(get-in fields [$ :db/pk]) (sorted (keys fields))))
  (when (> (length pks) 1)
    (errorf "entity %q: composite primary keys are not supported yet (:db/pk on %s)"
            name (string/join (map string pks) ", ")))
  (def pk (or (first pks)
              (when (in fields :id) :id)
              (errorf "entity %q: no primary key — mark a field with :db/pk (or name it :id)"
                      name)))
  (def rels
    (freeze (tabseq [[k v] :pairs (or (get opts :db/rels)
                                      (get schema-ann :db/rels) {})]
              k (rel-spec name k v))))
  (def version (first (filter |(get-in fields [$ :db/version])
                              (sorted (keys fields)))))
  (freeze
    {:name name
     :table table-name
     :schema node
     :pk pk
     :pk-column (get-in fields [pk :column])
     :version version
     :fields fields
     :columns (tuple ;(seq [k :in (sorted (keys fields))] (get-in fields [k :column])))
     :field-order (tuple ;(sorted (keys fields)))
     :column->field (freeze (tabseq [k :in (keys fields)]
                              (keyword (get-in fields [k :column])) k))
     :rels rels}))

(defn register!
  {:params [{:name :keyword & r}] :ret {:name :keyword & r}}
  "Register a descriptor under its name (re-registering replaces —
  REPL-friendly). Returns the descriptor."
  [desc]
  (put registry (desc :name) desc)
  desc)

(defn registered
  {:params [] :ret @[:keyword]}
  "Names of all registered entities."
  []
  (sorted (keys registry)))

(defn lookup
  {:params [:keyword]
   :ret (or {:name :keyword
             :table :string
             :schema {:type :keyword :props {:any :any} :children [:any]}
             :pk :keyword
             :pk-column :string
             :version (or :keyword :nil)
             :fields {:keyword {:name :keyword :column :string :optional :boolean & r}}
             :columns [:string]
             :field-order [:keyword]
             :column->field {:keyword :keyword}
             :rels {:keyword {:name :keyword :kind :keyword :entity :keyword :key :keyword
                              :through (or {:entity :keyword :key :keyword} :nil) & r}}}
            :nil)}
  "Descriptor by entity name, or nil."
  [name]
  (get registry name))

(defn entity?
  {:params [:any] :ret :boolean
   :narrows {:name :keyword
             :table :string
             :schema {:type :keyword :props {:any :any} :children [:any]}
             :pk :keyword
             :pk-column :string
             :version (or :keyword :nil)
             :fields {:keyword {:name :keyword :column :string :optional :boolean & r}}
             :columns [:string]
             :field-order [:keyword]
             :column->field {:keyword :keyword}
             :rels {:keyword {:name :keyword :kind :keyword :entity :keyword :key :keyword
                              :through (or {:entity :keyword :key :keyword} :nil) & r}}}}
  "Is x a descriptor?"
  [x]
  (and (dictionary? x) (not (nil? (get x :column->field)))))

(defn resolve
  {:params [:any]
   :ret {:name :keyword
         :table :string
         :schema {:type :keyword :props {:any :any} :children [:any]}
         :pk :keyword
         :pk-column :string
         :version (or :keyword :nil)
         :fields {:keyword {:name :keyword :column :string :optional :boolean & r}}
         :columns [:string]
         :field-order [:keyword]
         :column->field {:keyword :keyword}
         :rels {:keyword {:name :keyword :kind :keyword :entity :keyword :key :keyword
                          :through (or {:entity :keyword :key :keyword} :nil) & r}}}
   :throws [:string]}
  ``The descriptor behind a name (:User), a schema node defined by
  `defentity`, or a descriptor itself.``
  [x]
  (cond
    (entity? x) x
    (keyword? x)
    (or (get registry x)
        (errorf "unknown entity %q (registered: %s)"
                x (string/join (map |(string/format "%q" $) (registered)) " ")))
    (schema/node? x)
    (if-let [n (get-in x [:props entity-key])]
      (resolve n)
      (error "this schema is not an entity — declare it with defentity"))
    (errorf "expected an entity (descriptor, :Name or a defentity schema), got %q" x)))

(defn define!
  {:params [:keyword :any (or [:any] @[:any] :nil)]
   :ret {:type :keyword :props {:any :any} :children [:any]}
   :throws [:string]}
  ``Register an entity and return its normalized schema — the runtime
  half of `defentity` (void/db re-exports the macro through this same
  function, so there is one implementation).

  The db-mapping is carried on the schema too, as :db/* props: a
  descriptor is what the repository resolves, and
  (schema/db-annotations User) is what everything reading schemas
  alone — admin widgets, migrations-diff — gets to see. One
  declaration, both readers.``
  [name form &opt kvs]
  (default kvs [])
  (register! (descriptor name form ;kvs))
  (def props (merge-into @{entity-key name} (table ;kvs)))
  (schema/register! name [:map (table/to-struct props) form]))

(defmacro defentity
  {:params [:symbol :any :any] :ret :any}
  ``Define an entity: a schema *and* its db-mapping in one declaration
.

      (defentity User
        {:id       [:uuid {:db/pk true}]
         :email    [:string {:format :email :db/unique true}]
         :brand-id [:uuid {:db/fk :Brand}]}
        :db/table "users"
        :db/rels  {:brand [:belongs-to :Brand :brand-id]
                   :bets  [:has-many :Bet :user-id]
                   # through the join table, which is an entity like
                   # any other: :user-id points here, :group-id there
                   :groups {:kind :has-many :entity :Group :key :user-id
                            :through {:entity :Membership :key :group-id}}})

  The binding is the normalized schema — registered as :User, so
  (schema/select User [:email]) projects a DTO and [:ref :User] works —
  and the mapping is registered as the :User descriptor, which every
  repository call resolves through.``
  [name form & kvs]
  ~(def ,name (,define! ,(keyword name) ,form [,;kvs])))

# -- instances (table prototypes) ----------------------------------------

(defn- own-values
  {:params [@{:any :any}] :ret {:any :any}}
  "The instance's own column values as a frozen struct — the prototype
  chain is deliberately left out of the snapshot."
  [inst]
  (freeze (tabseq [[k v] :pairs inst] k v)))

(defn- proto-for
  {:params [:any {:any :any}]
   :ret @{:void.db/descriptor :any :void.db/snapshot {:any :any} :void.db/preloaded @{:any :any}}}
  "The prototype every loaded instance shares: its descriptor, the
  load-time snapshot `save!` diffs against, and the (empty, to start)
  table of preloaded relations."
  [desc snapshot]
  @{:void.db/descriptor desc
    :void.db/snapshot snapshot
    :void.db/preloaded @{}})

(defn instance?
  {:params [:any] :ret :boolean :narrows @{:any :any}}
  "Is x a loaded entity instance (a table with an entity prototype)?"
  [x]
  (and (table? x)
       (not (nil? (get (or (table/getproto x) @{}) :void.db/descriptor)))))

(defn descriptor-of
  {:params [@{:any :any}]
   :ret {:name :keyword
         :table :string
         :schema {:type :keyword :props {:any :any} :children [:any]}
         :pk :keyword
         :pk-column :string
         :version (or :keyword :nil)
         :fields {:keyword {:name :keyword :column :string :optional :boolean & r}}
         :columns [:string]
         :field-order [:keyword]
         :column->field {:keyword :keyword}
         :rels {:keyword {:name :keyword :kind :keyword :entity :keyword :key :keyword
                          :through (or {:entity :keyword :key :keyword} :nil) & r}}}
   :throws [:string]}
  "The descriptor of a loaded instance."
  [inst]
  (or (get (or (table/getproto inst) @{}) :void.db/descriptor)
      (errorf "not a loaded entity instance: %q" inst)))

(defn snapshot
  {:params [@{:any :any}] :ret (or {:any :any} :nil)}
  "The load-time column values of an instance — what `save!` diffs
  against."
  [inst]
  (get (table/getproto inst) :void.db/snapshot))

(defn from-row
  {:params [{:column->field {:keyword :keyword} & r} {:any :any} (or {:keyword :keyword} :nil)]
   :ret @{:any :any}}
  ``Map a driver row onto an entity instance: known columns become
  field keys, unknown ones (join extras) are kept as they came, and
  `aliases` — a column-keyword to field-keyword table — renames the
  ones the query named itself (`:extra`), so a caller reads them back
  under the spelling it wrote.

  The extras are part of the snapshot, deliberately: they are not
  fields, and a snapshot without them would make every one of them a
  "change" that `save!` then refused to write.``
  [desc row &opt aliases]
  (def inst @{})
  (eachp [col v] row
    (def k (keyword col))
    (put inst (or (get-in desc [:column->field k])
                  (get aliases k)
                  k)
         v))
  (table/setproto inst (proto-for desc (own-values inst))))

(defn to-row
  {:params [{:fields {:keyword {:column :string & r}} :name :keyword :field-order [:keyword] & r}
            {:keyword :any}]
   :ret @{:string :any}
   :throws [:string]}
  ``Column map for a write: field keys to column names, unknown keys
  rejected (a typo must not silently vanish from an INSERT).

  The column names are kept as strings so the builder quotes them
  verbatim: a :db/column whose spelling is not snake_case (say
  "createdAt") would otherwise be snake_cased into a column that does
  not exist (the keyword identifier path snakes; the string one does
  not).``
  [desc attrs]
  (def out @{})
  (eachp [k v] attrs
    (def f (or (get-in desc [:fields k])
               (errorf "entity %q has no field %q (fields: %s)"
                       (desc :name) k
                       (string/join (map |(string/format "%q" $) (desc :field-order)) " "))))
    (put out (f :column) v))
  out)

(defn changes
  {:params [@{:any :any}] :ret @{:any :any}}
  ``The fields of an instance that differ from its snapshot — what
  `save!` would write.``
  [inst]
  (def snap (snapshot inst))
  (def out @{})
  (eachp [k v] inst
    (unless (deep= v (get snap k))
      (put out k v)))
  out)

(defn dirty?
  {:params [@{:any :any}] :ret :boolean :narrows :any}
  "Does this instance differ from its snapshot?"
  [inst]
  (not (empty? (changes inst))))

# -- identity map (opt-in, per scope) ------------------------------------

(def identity-map-dyn
  "Dynamic binding: the per-scope identity map (off unless bound)."
  :void.db/identity-map)

(defn with-identity-map*
  {:params [(fn [] :any)] :ret :any}
  "Run (f) with a fresh identity map: `find` returns the same instance
  for the same primary key inside the scope."
  [f]
  (with-dyns [identity-map-dyn @{}] (f)))

(defmacro with-identity-map
  {:params [:any] :ret :any}
  ``Run the body with a per-scope identity map (opt-in, off by default)
  — repeated `find`s of one row return one instance.``
  [& body]
  ~(,with-identity-map* (fn identity-map-body [] ,;body)))

(defn- id-cache
  {:params [{:name :keyword & r} :any] :ret (or @{:any :any} :nil)}
  "The identity-mapped instance already loaded for `id` in the current
  scope, or nil when there is none (no scope bound, or a first load)."
  [desc id]
  (when-let [m (dyn identity-map-dyn)]
    (get m [(desc :name) id])))

(defn- id-cache!
  {:params [{:name :keyword & r} :any @{:any :any}] :ret @{:any :any}}
  "Remember `inst` under `id` in the current identity map, when one is
  bound; returns `inst` either way."
  [desc id inst]
  (when-let [m (dyn identity-map-dyn)]
    (put m [(desc :name) id] inst))
  inst)

# -- N+1 guard -----------------------------------------------------------

(def guard-dyn
  "Dynamic binding: the N+1 guard mode (:off, :warn, :strict) —
  normally set from [:db :n1-guard] by the :db/pool component."
  :void.db/n1-guard)

(var default-guard
  "Guard mode when no dyn is bound (the component sets it from config:
  :warn outside :prod, :off in :prod)."
  :warn)

(defn guard-mode
  {:params [] :ret (enum :off :warn :strict)}
  "The active N+1 guard mode."
  []
  (or (dyn guard-dyn) default-guard))

(defn- call-site
  {:params [] :ret :string}
  "The innermost stack frame outside void/db — where the unplanned
  `rel` was called."
  []
  (var out nil)
  (each frame (debug/stack (fiber/current))
    (when (nil? out)
      (def src (get frame :source))
      (when (and src
                 (not (string/find "void/db/" src))
                 (not (string/has-prefix? "src/core/" src)))
        (set out (string src ":" (get frame :source-line "?"))))))
  (or out "?"))

(defn- guard!
  {:params [{:name :keyword & r} :keyword] :ret :nil :throws [:string]}
  "Warn (or, under :strict, throw) that `rname` was navigated without
  a :preload — the N+1 an unplanned `rel` is."
  [desc rname]
  (def mode (guard-mode))
  (unless (= :off mode)
    (def at (call-site))
    (def msg
      (string/format
        "N+1: relation %q of %q was not preloaded — add :preload [%q] to the query (at %s)"
        rname (desc :name) rname at))
    (if (= :strict mode)
      (error msg)
      (log/warn msg :ns "void.db.entity"
                :entity (desc :name) :relation rname :at at)))
  nil)

# -- reading -------------------------------------------------------------

(defn- rel-of
  {:params [{:name :keyword :rels {:keyword :any} & r} :keyword]
   :ret {:name :keyword :kind :keyword :entity :keyword :key :keyword
         :through (or {:entity :keyword :key :keyword} :nil) & r}
   :throws [:string]}
  "The relation record `rname` names on `desc`, or an error listing
  what the entity actually declares."
  [desc rname]
  (or (get-in desc [:rels rname])
      (errorf "entity %q has no relation %q (relations: %s)"
              (desc :name) rname
              (string/join (map |(string/format "%q" $)
                                (sorted (keys (desc :rels)))) " "))))

(def- query-opts
  {:where true :order-by true :limit true :offset true :join true
   :left-join true :group-by true :having true :preload true :sql-opts true
   :extra true :lock true})

(defn- check-opts
  {:params [{:any :any} {:keyword :boolean} :string] :ret :nil :throws [:string]}
  "A mistyped query option must fail, not quietly change the query."
  [opts allowed who]
  (eachk k opts
    (unless (in allowed k)
      (errorf "%s: unknown option %q (allowed: %s)"
              who k
              (util/names-str (keys allowed))))))

(defn- extra-aliases
  {:params [{:extra (or {:keyword :any} :nil) & r}]
   :ret (or @{:keyword :keyword} :nil)
   :throws [:string]}
  ``The `:extra` map as {column-keyword field-keyword}: what a joined
  column comes back as, and what the caller asked to read it under.
  The builder snake_cases the alias into the statement, so that is the
  key the driver hands back.``
  [opts]
  (def extra (get opts :extra))
  (when extra
    (unless (dictionary? extra)
      (errorf "db :extra must be a map of alias -> expression, got %q" extra))
    (tabseq [k :keys extra] (keyword (builder/snake k)) k)))

(defn- select-stmt
  {:params [{:columns [:string] :table :string & r}
            {:extra (or {:keyword :any} :nil) :where :any :order-by :any :limit :any
             :offset :any :join :any :left-join :any :group-by :any :having :any
             :lock :any & r}]
   :ret @{:select [:any] :from :string & r}}
  "The builder statement map for a `query`/`one`/`find` call: every
  column of `desc`, plus `:extra`'s joined columns under their own
  names, plus whichever of the passed-through query options were
  given."
  [desc opts]
  # [:col name], not (keyword name): the column names are the descriptor's
  # own spelling (a :db/column may be "createdAt"), and the keyword path
  # would snake_case them into columns that do not exist
  (def cols (array ;(map |[:col $] (desc :columns))))
  # the joined columns a query asks for by name — a join could always
  # filter, and this is what lets it bring something back
  (when-let [extra (get opts :extra)]
    (each k (sorted (keys extra))
      (array/push cols [:as (get extra k) k])))
  (def stmt @{:select (tuple ;cols) :from (desc :table)})
  (each k [:where :order-by :limit :offset :join :left-join :group-by :having :lock]
    (unless (nil? (get opts k))
      (put stmt k (get opts k))))
  stmt)

(def- preload-opts
  {:where true :order-by true :preload true :sql-opts true})

(defn- preload-options
  {:params [:keyword {:any :any}] :ret @{:any :any} :throws [:string]}
  ``One relation's preload options, checked. `:limit` and `:offset` are
  refused by name rather than by the allow-list, because the mistake
  they are is worth stating: a preload is **one** query for every
  parent, so a LIMIT would cap the batch and not each parent's rows —
  five rows in total rather than five per user.``
  [rname opts]
  (unless (dictionary? opts)
    (errorf "db :preload %q: options must be a map, got %q" rname opts))
  (eachk k opts
    (unless (in preload-opts k)
      (if (or (= :limit k) (= :offset k))
        (errorf (string "db :preload %q: %q would cap the whole batch rather than "
                        "each parent's rows — a preload is one query for all of "
                        "them. Narrow it with :where, or load the few rows you "
                        "want per parent yourself")
                rname k)
        (errorf "db :preload %q: unknown option %q (allowed: %s)"
                rname k (util/names-str (keys preload-opts))))))
  (table ;(kvs opts)))

(defn- normalize-preload
  {:params [:any] :ret @{:keyword @{:any :any}} :throws [:string]}
  ``Preload spec -> {rel-key options}:

      [:brand {:bets [:market]}]              two relations, the second
                                              with a nested preload
      [[:bets {:where [:> :amount 100]
               :order-by [[:placed-at :desc]]
               :preload [:market]}]]          one, with options

  The two spellings never collide: the value of a *map* entry is a
  nested preload spec, and the second half of a *tuple* entry is
  options. Options may carry their own :preload, which is the same
  nesting one level down.``
  [spec]
  (def out @{})
  (defn add-nested [k v] (put out k (if (nil? v) @{} @{:preload v})))
  (cond
    (nil? spec) nil
    (keyword? spec) (add-nested spec nil)
    (dictionary? spec) (eachp [k v] spec (add-nested k v))
    (indexed? spec)
    (each item spec
      (cond
        (keyword? item) (add-nested item nil)
        (dictionary? item) (eachp [k v] item (add-nested k v))
        (and (indexed? item) (= 2 (length item)) (keyword? (first item)))
        (put out (first item) (preload-options (first item) (in item 1)))
        (errorf (string "db :preload entry must be a keyword, a map or "
                        "[:relation {options}], got %q")
                item)))
    (errorf "db :preload must be a keyword, tuple or map, got %q" spec))
  out)

(var- load-preloads nil)

(defn- load-rows
  {:params [{:table :string :pk :keyword :name :keyword :column->field {:keyword :keyword} & r}
            {:sql-opts :any :preload :any :extra (or {:keyword :any} :nil) :where :any
             :order-by :any :limit :any :offset :any :join :any :left-join :any
             :group-by :any :having :any :lock :any & r}]
   :ret @[@{:any :any}]
   :throws [:string]}
  "Run the select and map every row onto a loaded instance, caching
  each by primary key and running any requested preload."
  [desc opts]
  (def rows (state/query (select-stmt desc opts) (get opts :sql-opts)))
  (def aliases (extra-aliases opts))
  (def out (seq [r :in rows] (from-row desc r aliases)))
  (each inst out
    (id-cache! desc (get inst (desc :pk)) inst))
  (when-let [spec (get opts :preload)]
    (load-preloads desc out spec))
  out)

# a belongs-to with no match preloads to nil, and a table cannot hold
# nil — the sentinel keeps "loaded, and it is nothing" distinct from
# "never loaded", so a missing parent is not re-queried per row
(def- preloaded-nil :void.db/nil)

(defn- attach!
  {:params [@{:any :any} :keyword :any] :ret :any}
  "Record `value` (or the nil sentinel) as `rname`'s preloaded value on
  `inst`; returns `value` unchanged."
  [inst rname value]
  (put (get (table/getproto inst) :void.db/preloaded) rname
       (if (nil? value) preloaded-nil value))
  value)

(defn- preloaded-value
  {:params [@{:any :any} :keyword] :ret :any}
  "The preloaded value of `rname` on `inst`, with the nil sentinel read
  back as plain nil."
  [inst rname]
  (def v (get-in (table/getproto inst) [:void.db/preloaded rname]))
  (if (= preloaded-nil v) nil v))

(defn preloaded?
  {:params [@{:any :any} :keyword] :ret :boolean :narrows :any}
  "Has this relation been preloaded on this instance?"
  [inst rname]
  (not (nil? (get-in (table/getproto inst) [:void.db/preloaded rname]))))

(defn- group-by-key
  {:params [(or @[@{:any :any}] [@{:any :any}]) :keyword] :ret @{:any @[@{:any :any}]}}
  "Bucket instances by the value of `key` — the shape a batched load's
  results are joined back onto their parents through."
  [insts key]
  (def out @{})
  (each i insts
    (def k (get i key))
    (unless (nil? k)
      (array/push (or (get out k) (let [a @[]] (put out k a) a)) i)))
  out)

(defn- column-of
  {:params [{:fields {:keyword {:column :string & r}} :name :keyword & r} :keyword]
   :ret :string
   :throws [:string]}
  "The column name of `field` on `desc`."
  [desc field]
  (or (get-in desc [:fields field :column])
      (errorf "entity %q has no field %q" (desc :name) field)))

(defn- values-of
  {:params [(or @[@{:any :any}] [@{:any :any}]) :keyword] :ret @[:any]}
  "The distinct non-nil values of `field` across instances — the right
  side of the one IN a batched load is."
  [insts field]
  (distinct (filter |(not (nil? $)) (map |(get $ field) insts))))

(defn- load-batch
  {:params [{:table :string :pk :keyword :name :keyword :column->field {:keyword :keyword}
             :fields {:keyword {:column :string & r}} & r}
            :keyword (or @[:any] [:any])
            {:where :any :order-by :any :preload :any :sql-opts :any & r}]
   :ret @[@{:any :any}]
   :throws [:string]}
  ``The rows of `target` whose `field` is one of `values`, under this
  relation's preload options: the options' :where is ANDed onto the
  IN rather than replacing it, and their :preload is the nesting one
  level down.``
  [target field values opts]
  (if (empty? values)
    @[]
    (load-rows target
               (merge (table ;(kvs opts))
                      {:where (builder/all-of
                                [:in [:col (column-of target field)] (tuple ;values)]
                                (get opts :where))
                       :preload (get opts :preload)}))))

(defn- attach-hits!
  {:params [{:kind :keyword & r} @{:any :any} :keyword (or @[:any] [:any])] :ret :any}
  "Attach a relation's batch of matches to one instance: the whole
  tuple for has-many, the first (and only) row otherwise."
  [relation inst rname hits]
  (attach! inst rname
           (if (= :has-many (relation :kind)) (tuple ;hits) (first hits))))

(defn- load-direct
  {:params [{:pk :keyword & r}
            (or @[@{:any :any}] [@{:any :any}])
            {:kind :keyword :key :keyword :name :keyword & r}
            {:pk :keyword :table :string :name :keyword :column->field {:keyword :keyword}
             :fields {:keyword {:column :string & r}} & r}
            {:where :any :order-by :any :preload :any :sql-opts :any & r}]
   :ret :nil
   :throws [:string]}
  ``A relation with no middle: one batched IN, never one query per
  row. belongs-to reads our :key against the target's primary key;
  has-many / has-one read our primary key against the target's :key.``
  [desc insts relation target opts]
  (def belongs? (= :belongs-to (relation :kind)))
  (def local (if belongs? (relation :key) (desc :pk)))
  (def remote (if belongs? (get target :pk) (relation :key)))
  (def related (load-batch target remote (values-of insts local) opts))
  (def by-key (group-by-key related remote))
  (each inst insts
    (attach-hits! relation inst (relation :name)
                  (get by-key (get inst local) @[]))))

(defn- load-through
  {:params [{:pk :keyword & r}
            (or @[@{:any :any}] [@{:any :any}])
            {:key :keyword :through {:entity :keyword :key :keyword} :name :keyword & r}
            {:pk :keyword :table :string :name :keyword :column->field {:keyword :keyword}
             :fields {:keyword {:column :string & r}} & r}
            {:where :any :order-by :any :preload :any :sql-opts :any & r}]
   :ret :nil
   :throws [:string]}
  ``A relation through a middle entity — the join table a many-to-many
  is: two queries for any number of parents, one for the links and one
  for the targets they name. The link rows are entities like any
  other, so a join table declared as an entity is the only thing this
  needs.``
  [desc insts relation target opts]
  (def middle (resolve (get-in relation [:through :entity])))
  # the field on the middle that points back at us, and the one that
  # points at the target
  (def back (relation :key))
  (def forward (get-in relation [:through :key]))
  (def links (load-batch middle back (values-of insts (desc :pk)) {}))
  (def related
    (load-batch target (target :pk) (values-of links forward) opts))
  (def by-id (tabseq [r :in related] (get r (target :pk)) r))
  (def links-by-parent (group-by-key links back))
  (each inst insts
    (def rows (get links-by-parent (get inst (desc :pk)) @[]))
    (attach-hits! relation inst (relation :name)
                  (filter |(not (nil? $)) (map |(get by-id (get $ forward)) rows)))))

(set load-preloads
  (fn load-preloads [desc insts spec]
    (when (empty? insts) (break))
    (eachp [rname opts] (normalize-preload spec)
      (def relation (rel-of desc rname))
      (def target (resolve (relation :entity)))
      (if (relation :through)
        (load-through desc insts relation target opts)
        (load-direct desc insts relation target opts)))))

(defn query
  {:params [:any
            (or {:where :any :order-by :any :limit :any :offset :any :join :any
                :left-join :any :group-by :any :having :any :preload :any
                :sql-opts :any :extra (or {:keyword :any} :nil) :lock :any & r}
                :nil)]
   :ret @[@{:any :any}]
   :throws [:string]}
  ``Load entities (Data Mapper — plain data in, plain data out):

      (db/query User {:where [:= :brand-id b]
                      :order-by [[:created-at :desc]] :limit 50
                      :preload [:brand]})

  Keys: :where :order-by :limit :offset :join :left-join :group-by
  :having :lock (see void/db/builder), plus two of this layer's own:

  `:extra` — columns from a joined table, under names of your own:

      (db/query Order {:join [["users" [:= :users.id :orders.user-id]]]
                       :extra {:buyer-email :users.email}})

  A join could always *filter*; this is what lets it bring something
  back. The extras are ordinary keys on the instance and are part of
  its snapshot, so they are not fields and `save!` never tries to
  write them.

  `:preload` — the explicit, batched relation load. A relation name, a
  map for nesting, or a tuple entry with options of its own:

      :preload [:brand
                {:bets [:market]}
                [:bets {:where [:> :amount 100]
                        :order-by [[:placed-at :desc]]}]]

  Returns an array of instances.``
  [ent &opt opts]
  (default opts {})
  (check-opts opts query-opts "db/query")
  (load-rows (resolve ent) opts))

(defn one
  {:params [:any
            (or {:where :any :order-by :any :limit :any :offset :any :join :any
                :left-join :any :group-by :any :having :any :preload :any
                :sql-opts :any :extra (or {:keyword :any} :nil) :lock :any & r}
                :nil)]
   :ret (or @{:any :any} :nil)
   :throws [:string]}
  "Like `query` with :limit 1 — the first matching entity or nil."
  [ent &opt opts]
  (default opts {})
  (first (query ent (merge opts {:limit 1}))))

(defn find
  {:params [:any :any
            (or {:where :any :order-by :any :limit :any :offset :any :join :any
                :left-join :any :group-by :any :having :any :preload :any
                :sql-opts :any :extra (or {:keyword :any} :nil) :lock :any & r}
                :nil)]
   :ret (or @{:any :any} :nil)
   :throws [:string]}
  ``Load one entity by primary key, or nil:

      (db/find User id)
      (db/find User id {:preload [:brand]})``
  [ent id &opt opts]
  (default opts {})
  (def desc (resolve ent))
  (or (when (nil? (get opts :preload)) (id-cache desc id))
      (one desc (merge opts {:where [:= [:col (desc :pk-column)] id]}))))

(defn find!
  {:params [:any :any
            (or {:where :any :order-by :any :limit :any :offset :any :join :any
                :left-join :any :group-by :any :having :any :preload :any
                :sql-opts :any :extra (or {:keyword :any} :nil) :lock :any & r}
                :nil)]
   :ret @{:any :any}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Like `find`, but throws when the row does not exist."
  [ent id &opt opts]
  (or (find ent id opts)
      (errors/raise :void.db/not-found
                    (string/format "%q %q not found" ((resolve ent) :name) id)
                    {:entity ((resolve ent) :name) :id id})))

(defn count
  {:params [:any (or {:where :any & r} :nil)] :ret :number :throws [:string]}
  "How many rows match (no entity instances built). opts: :where."
  [ent &opt opts]
  (default opts {})
  (check-opts opts {:where true} "db/count")
  (def desc (resolve ent))
  (def stmt @{:select [[:raw "count(*) AS n"]] :from (desc :table)})
  (when-let [w (get opts :where)] (put stmt :where w))
  (or (state/value stmt) 0))

(defn exists?
  {:params [:any (or {:where :any & r} :nil)] :ret :boolean :throws [:string]}
  "Does any row match?"
  [ent &opt opts]
  (pos? (count ent opts)))

(defn rel
  {:params [@{:any :any} :keyword] :ret :any :throws [:string]}
  ``Navigate a relation of a loaded instance:

      (db/rel u :brand)

  Preloaded relations are a table lookup. Anything else is an N+1 in
  the making: in dev it warns with the call site and loads the row, in
  :strict it throws. Either way the fix is :preload.``
  [inst rname]
  (def desc (descriptor-of inst))
  (rel-of desc rname)
  (unless (preloaded? inst rname)
    (guard! desc rname)
    (load-preloads desc [inst] rname))
  (preloaded-value inst rname))

(defn preload!
  {:params [:any (or @{:any :any} @[@{:any :any}] [@{:any :any}]) :any]
   :ret (or @{:any :any} @[@{:any :any}] [@{:any :any}])
   :throws [:string]}
  ``Preload relations onto already-loaded instances — the batched
  escape hatch when the rows came from somewhere else:

      (db/preload! User users [:brand])``
  [ent insts spec]
  (load-preloads (resolve ent) (if (indexed? insts) insts [insts]) spec)
  insts)

# -- checking a write ----------------------------------------------------

(def- check-opts {:partial true :coerce true})

(defn check-schema
  {:params [:any :boolean?]
   :ret {:type :keyword :props {:any :any} :children [:any]}
   :throws [:string]}
  ``The schema a write is checked against: the entity's own
  declaration, closed — an unknown key is an error at write time
  (`to-row` refuses it), so it is an error here — and with the primary
  key optional, because a table that numbers its own rows supplies it.

  `partial?` makes every field optional, which is the shape of a
  patch: a field missing from an `update!` is not a field missing from
  the row.``
  [ent &opt partial?]
  (def desc (resolve ent))
  (def n (schema/normalize (desc :schema)))
  (def entries
    (tabseq [[k sub] :in (n :children)]
      k (if (or (= :optional (sub :type))
                (and (not partial?) (not= k (desc :pk))))
          sub
          (schema/optional sub))))
  (schema/closed [:map (n :props) entries]))

(defn check
  {:params [:any :any (or {:partial :boolean? :coerce :boolean?} :nil)]
   :ret {:value :any :errors [:any]}
   :throws [:string]}
  ``Would this write be accepted? Validates `attrs` against the
  entity's declaration and answers in `schema/check`'s format —
  `{:value ... :errors [...]}` — so a route, a form or a job renders
  the failure the way it renders every other schema failure, and
  nothing is written by asking.

      (def res (db/check User attrs))
      (if (empty? (res :errors))
        (db/insert! User (res :value))
        (render-form-errors (res :errors)))

  opts: `:partial true` for a patch (see `check-schema`), `:coerce
  true` to take the strings a form submits and hand back the values a
  column holds.

  Deliberately not a changeset: nothing is wrapped, nothing is
  threaded through the write, and `insert!` does not secretly call
  this. It is one question with one answer, asked where the caller
  decides an invalid write is a *refusal* rather than a panic — the
  seam between the shape and the write, and nothing more.``
  [ent attrs &opt opts]
  (default opts {})
  (eachk k opts
    (unless (in check-opts k)
      (errorf "db/check: unknown option %q (allowed: %s)"
              k (util/names-str (keys check-opts)))))
  (schema/check (check-schema ent (get opts :partial))
                attrs
                (if (get opts :coerce) {:coerce true} {})))

(defn check!
  {:params [:any :any (or {:partial :boolean? :coerce :boolean?} :nil)]
   :ret :any
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  ``A `check` that raises: the (possibly coerced) attributes when they
  validate, and otherwise the same `:void.schema/invalid` envelope
  `schema/check!` raises — status 422, every error under `:data`. What
  a route calls when an invalid write is a refusal to answer rather
  than a branch to take.``
  [ent attrs &opt opts]
  (default opts {})
  (def res (check ent attrs opts))
  (if (empty? (res :errors))
    (res :value)
    (errors/raise :void.schema/invalid
                  (string/join (map schema/error-str (res :errors)) "; ")
                  {:errors (res :errors) :value (res :value)
                   :entity ((resolve ent) :name)})))

# -- writing -------------------------------------------------------------

(defn- reload-by-pk
  {:params [{:table :string :pk-column :string & r} :any] :ret (or @{:any :any} :nil) :throws [:string]}
  "Re-read a row by primary key after a write — what `insert!` falls
  back to when the driver gave neither RETURNING nor an insert id."
  [desc id]
  (one desc {:where [:= [:col (desc :pk-column)] id]}))

(defn insert!
  {:params [:any {:keyword :any}]
   :ret @{:any :any}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  ``Insert one row and return the loaded entity:

      (db/insert! User {:email "a@b.c" :brand-id b})

  Unknown keys are an error, not a silent drop. Drivers with RETURNING
  hand back the stored row (defaults included); elsewhere the row is
  re-read by the id the driver reports.``
  [ent attrs]
  (def desc (resolve ent))
  (def row (to-row desc attrs))
  (def drv (state/driver))
  (def stmt @{:insert (desc :table) :values row})
  (when (drv :returning) (put stmt :returning true))
  (state/with-conn*
    (fn insert-scope [entry]
      (def res (state/run stmt))
      (def returned (first (get res :rows [])))
      (cond
        returned (from-row desc returned)
        # the id the row got, from the one place the contract has for
        # it: what the caller supplied, or what the driver's :insert-id
        # says the INSERT made. There used to be a third reading here —
        # `(get res :inserted-id)` off the driver result — which no
        # driver has ever written
        (let [id (or (get attrs (desc :pk))
                     (when-let [f (drv :insert-id)] (f (entry :conn) res)))]
          (or (when id (reload-by-pk desc id))
              # no RETURNING and no id: hand back what was written
              (from-row desc row)))))))

(defn insert-all!
  {:params [:any (or @[{:keyword :any}] [{:keyword :any}])]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Insert several rows in one statement; returns the affected count."
  [ent rows]
  (def desc (resolve ent))
  (when (empty? rows) (break 0))
  (state/execute! {:insert (desc :table)
                   :values (tuple ;(map |(to-row desc $) rows))}))

(defn update!
  {:params [:any :any {:keyword :any}]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  ``Patch a row by primary key; returns the number of rows written:

      (db/update! User id {:email "new@b.c"})``
  [ent id patch]
  (def desc (resolve ent))
  (when (empty? patch) (break 0))
  (state/execute! {:update (desc :table)
                   :set (to-row desc patch)
                   :where [:= [:col (desc :pk-column)] id]}))

(defn delete!
  {:params [:any :any]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Delete a row by primary key; returns the number of rows deleted."
  [ent id]
  (def desc (resolve ent))
  (state/execute! {:delete (desc :table)
                   :where [:= [:col (desc :pk-column)] id]}))

(defn delete-where!
  {:params [:any :any]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Delete every row matching a where clause; returns the count."
  [ent where]
  (def desc (resolve ent))
  (state/execute! {:delete (desc :table) :where where}))

(defn- refresh-snapshot!
  {:params [@{:any :any}] :ret @{:any :any}}
  "Replace the instance's snapshot with its current values, after a
  write has landed — what makes the next `changes` empty again."
  [inst]
  (def proto (table/getproto inst))
  (put proto :void.db/snapshot (own-values inst))
  inst)

(defn save!
  {:params [@{:any :any} (or {:version :any & r} :nil)]
   :ret @{:any :any}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  ``Write back the fields that changed since the instance was loaded —
  the Active Record half, and nothing more:

      (-> u (put :email "x@y.z") (db/save!))

  A partial UPDATE of the diffed columns only; an unchanged instance
  writes nothing. With a :db/version field the UPDATE is guarded by
  the loaded version and a lost race throws instead of overwriting.
  Returns the instance with a refreshed snapshot.

  `opts` takes `:version` — the version the caller read, when that is
  not the one this instance was loaded with. A form is the case that
  needs it: it was drawn from a row read minutes ago and posts back
  much later, so the row the handler loads in order to save is already
  somebody else's, and guarding by *its* version guards by a value that
  is fresh by construction. Passing the version the form carried is
  what turns a lost race into a conflict instead of a silent
  overwrite.``
  [inst &opt opts]
  (def desc (descriptor-of inst))
  (def diff (changes inst))
  (when (empty? diff) (break inst))
  (def id (get (snapshot inst) (desc :pk)))
  (when (nil? id)
    (errorf "%q has no primary key value — insert! it first" (desc :name)))
  (def vfield (desc :version))
  (def expected
    (when vfield
      (let [given (get (or opts {}) :version)]
        (if (nil? given) (get (snapshot inst) vfield) given))))
  (def where
    (if vfield
      [:and
       [:= [:col (desc :pk-column)] id]
       [:= [:col (get-in desc [:fields vfield :column])] expected]]
      [:= [:col (desc :pk-column)] id]))
  (def to-write
    (if vfield
      (merge diff {vfield (inc (or expected 0))})
      diff))
  (def n (state/execute! {:update (desc :table)
                          :set (to-row desc to-write)
                          :where where}))
  (when (zero? n)
    (if vfield
      (errorf "%q %q was modified concurrently (version %q) — reload and retry"
              (desc :name) id expected)
      (errorf "%q %q no longer exists — nothing was updated" (desc :name) id)))
  (when vfield (put inst vfield (get to-write vfield)))
  (refresh-snapshot! inst))

(defn reload
  {:params [@{:any :any}
            (or {:where :any :order-by :any :limit :any :offset :any :join :any
                :left-join :any :group-by :any :having :any :preload :any
                :sql-opts :any :extra (or {:keyword :any} :nil) :lock :any & r}
                :nil)]
   :ret (or @{:any :any} :nil)
   :throws [:string]}
  "Re-read the instance from the database; returns a fresh instance."
  [inst &opt opts]
  (def desc (descriptor-of inst))
  (find desc (get (snapshot inst) (desc :pk)) opts))
