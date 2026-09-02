### void/db/entity — Data Mapper core with thin AR sugar (SPEC.md
### §5.9, ADR-0009).
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
### preloaded relations: `pp` prints the columns and nothing else,
### `keys` lists the columns, `put`/`merge` are how you change a
### record. `save!` diffs the table against its snapshot and writes
### only the changed columns; there is no lazy loading, no Unit of
### Work, and deliberately no lifecycle callbacks (audit and domain
### events belong in the outbox, ADR-0012).
###
### N+1 is a bug the layer refuses to hide: `rel` on a relation nobody
### preloaded warns with the call site in dev and throws under
### :strict. The fix it names is always the same — declare :preload.

(import void/core/schema :as schema)
(import void/core/log :as log)
(import ./builder :as builder)
(import ./state :as state)

# -- descriptors ---------------------------------------------------------

(def entity-key
  "Schema prop holding the entity name — the bridge from a schema node
  back to its descriptor."
  :void.db/entity)

(def- registry @{})

(def- rel-kinds {:belongs-to true :has-many true :has-one true})

(defn- rel-spec [ename rname form]
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
            (string/join (map |(string/format "%q" $) (sorted (keys rel-kinds))) " ")))
  (unless (keyword? (get spec :entity))
    (errorf "entity %q: relation %q must name a target entity keyword, got %q"
            ename rname (get spec :entity)))
  (unless (keyword? (get spec :key))
    (errorf "entity %q: relation %q must name a key field, got %q"
            ename rname (get spec :key)))
  (freeze (merge @{:name rname} spec)))

(defn- field-map [node ename]
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
  "Register a descriptor under its name (re-registering replaces —
  REPL-friendly). Returns the descriptor."
  [desc]
  (put registry (desc :name) desc)
  desc)

(defn registered
  "Names of all registered entities."
  []
  (sorted (keys registry)))

(defn lookup
  "Descriptor by entity name, or nil."
  [name]
  (get registry name))

(defn entity?
  "Is x a descriptor?"
  [x]
  (and (dictionary? x) (not (nil? (get x :column->field)))))

(defn resolve
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
  ``Register an entity and return its normalized schema — the runtime
  half of `defentity` (void/db re-exports the macro through this same
  function, so there is one implementation).

  The db-mapping is carried on the schema too, as :db/* props: a
  descriptor is what the repository resolves, and
  (schema/db-annotations User) is what everything reading schemas
  alone — admin widgets, migrations-diff — gets to see. One
  declaration, both readers (ADR-0008).``
  [name form &opt kvs]
  (default kvs [])
  (register! (descriptor name form ;kvs))
  (def props (merge-into @{entity-key name} (table ;kvs)))
  (schema/register! name [:map (table/to-struct props) form]))

(defmacro defentity
  ``Define an entity: a schema *and* its db-mapping in one declaration
  (ADR-0009).

      (defentity User
        {:id       [:uuid {:db/pk true}]
         :email    [:string {:format :email :db/unique true}]
         :brand-id [:uuid {:db/fk :Brand}]}
        :db/table "users"
        :db/rels  {:brand [:belongs-to :Brand :brand-id]
                   :bets  [:has-many :Bet :user-id]})

  The binding is the normalized schema — registered as :User, so
  (schema/select User [:email]) projects a DTO and [:ref :User] works —
  and the mapping is registered as the :User descriptor, which every
  repository call resolves through.``
  [name form & kvs]
  ~(def ,name (,define! ,(keyword name) ,form [,;kvs])))

# -- instances (table prototypes) ----------------------------------------

(defn- own-values
  "The instance's own column values as a frozen struct — the prototype
  chain is deliberately left out of the snapshot."
  [inst]
  (freeze (tabseq [[k v] :pairs inst] k v)))

(defn- proto-for [desc snapshot]
  @{:void.db/descriptor desc
    :void.db/snapshot snapshot
    :void.db/preloaded @{}})

(defn instance?
  "Is x a loaded entity instance (a table with an entity prototype)?"
  [x]
  (and (table? x)
       (not (nil? (get (or (table/getproto x) @{}) :void.db/descriptor)))))

(defn descriptor-of
  "The descriptor of a loaded instance."
  [inst]
  (or (get (or (table/getproto inst) @{}) :void.db/descriptor)
      (errorf "not a loaded entity instance: %q" inst)))

(defn snapshot
  "The load-time column values of an instance — what `save!` diffs
  against."
  [inst]
  (get (table/getproto inst) :void.db/snapshot))

(defn from-row
  ``Map a driver row onto an entity instance: known columns become
  field keys, unknown ones (join extras) are kept as they came. The
  prototype carries the descriptor and the snapshot.``
  [desc row]
  (def inst @{})
  (eachp [col v] row
    (def field (get-in desc [:column->field (keyword col)]))
    (put inst (or field (keyword col)) v))
  (table/setproto inst (proto-for desc (own-values inst))))

(defn to-row
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
  "Does this instance differ from its snapshot?"
  [inst]
  (not (empty? (changes inst))))

# -- identity map (opt-in, per scope) ------------------------------------

(def identity-map-dyn
  "Dynamic binding: the per-scope identity map (off unless bound)."
  :void.db/identity-map)

(defn with-identity-map*
  "Run (f) with a fresh identity map: `find` returns the same instance
  for the same primary key inside the scope."
  [f]
  (with-dyns [identity-map-dyn @{}] (f)))

(defmacro with-identity-map
  ``Run the body with a per-scope identity map (ADR-0009: opt-in, off
  by default) — repeated `find`s of one row return one instance.``
  [& body]
  ~(,with-identity-map* (fn identity-map-body [] ,;body)))

(defn- id-cache [desc id]
  (when-let [m (dyn identity-map-dyn)]
    (get m [(desc :name) id])))

(defn- id-cache! [desc id inst]
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
  "The active N+1 guard mode."
  []
  (or (dyn guard-dyn) default-guard))

(defn- call-site
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

(defn- guard! [desc rname]
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

(defn- rel-of [desc rname]
  (or (get-in desc [:rels rname])
      (errorf "entity %q has no relation %q (relations: %s)"
              (desc :name) rname
              (string/join (map |(string/format "%q" $)
                                (sorted (keys (desc :rels)))) " "))))

(def- query-opts
  {:where true :order-by true :limit true :offset true :join true
   :left-join true :group-by true :having true :preload true :sql-opts true})

(defn- check-opts
  "A mistyped query option must fail, not quietly change the query."
  [opts allowed who]
  (eachk k opts
    (unless (in allowed k)
      (errorf "%s: unknown option %q (allowed: %s)"
              who k
              (string/join (map |(string/format "%q" $) (sorted (keys allowed))) " ")))))

(defn- select-stmt [desc opts]
  # [:col name], not (keyword name): the column names are the descriptor's
  # own spelling (a :db/column may be "createdAt"), and the keyword path
  # would snake_case them into columns that do not exist
  (def stmt @{:select (tuple ;(map |[:col $] (desc :columns)))
              :from (desc :table)})
  (each k [:where :order-by :limit :offset :join :left-join :group-by :having]
    (unless (nil? (get opts k))
      (put stmt k (get opts k))))
  stmt)

(defn- normalize-preload
  ``Preload spec -> {rel-key nested-spec-or-false}:
  [:brand {:bets [:market]}] plans two relations, the second with a
  nested preload of its own. (`false` rather than nil: a table cannot
  hold a nil value, and "no nesting" must still register the key.)``
  [spec]
  (def out @{})
  (defn add [k v] (put out k (or v false)))
  (cond
    (nil? spec) nil
    (keyword? spec) (add spec nil)
    (dictionary? spec) (eachp [k v] spec (add k v))
    (indexed? spec) (each item spec
                      (cond
                        (keyword? item) (add item nil)
                        (dictionary? item) (eachp [k v] item (add k v))
                        (errorf "db :preload entry must be a keyword or a map, got %q" item)))
    (errorf "db :preload must be a keyword, tuple or map, got %q" spec))
  out)

(var- load-preloads nil)

(defn- load-rows [desc opts]
  (def rows (state/query (select-stmt desc opts) (get opts :sql-opts)))
  (def out (seq [r :in rows] (from-row desc r)))
  (each inst out
    (id-cache! desc (get inst (desc :pk)) inst))
  (when-let [spec (get opts :preload)]
    (load-preloads desc out spec))
  out)

# a belongs-to with no match preloads to nil, and a table cannot hold
# nil — the sentinel keeps "loaded, and it is nothing" distinct from
# "never loaded", so a missing parent is not re-queried per row
(def- preloaded-nil :void.db/nil)

(defn- attach! [inst rname value]
  (put (get (table/getproto inst) :void.db/preloaded) rname
       (if (nil? value) preloaded-nil value))
  value)

(defn- preloaded-value [inst rname]
  (def v (get-in (table/getproto inst) [:void.db/preloaded rname]))
  (if (= preloaded-nil v) nil v))

(defn preloaded?
  "Has this relation been preloaded on this instance?"
  [inst rname]
  (not (nil? (get-in (table/getproto inst) [:void.db/preloaded rname]))))

(defn- group-by-key [insts key]
  (def out @{})
  (each i insts
    (def k (get i key))
    (unless (nil? k)
      (array/push (or (get out k) (let [a @[]] (put out k a) a)) i)))
  out)

(set load-preloads
  (fn load-preloads [desc insts spec]
    (when (empty? insts) (break))
    (eachp [rname nested] (normalize-preload spec)
      (def relation (rel-of desc rname))
      (def target (resolve (relation :entity)))
      (def belongs? (= :belongs-to (relation :kind)))
      # belongs-to: our :key holds the target's pk; has-*: the target's
      # :key holds our pk — one batched IN query either way, never one
      # query per row (ADR-0009)
      (def local (if belongs? (relation :key) (desc :pk)))
      (def remote (if belongs? (get target :pk) (relation :key)))
      (def ids (distinct (filter |(not (nil? $)) (map |(get $ local) insts))))
      (def related
        (if (empty? ids)
          @[]
          (load-rows target
                     {:where [:in [:col (get-in target [:fields remote :column])]
                              (tuple ;ids)]
                      :preload (or nested nil)})))
      (def by-key (group-by-key related remote))
      (each inst insts
        (def hits (get by-key (get inst local) @[]))
        (attach! inst rname
                 (if (= :has-many (relation :kind))
                   (tuple ;hits)
                   (first hits)))))))

(defn query
  ``Load entities (Data Mapper — plain data in, plain data out):

      (db/query User {:where [:= :brand-id b]
                      :order-by [[:created-at :desc]] :limit 50
                      :preload [:brand]})

  Keys: :where :order-by :limit :offset :join :left-join :group-by
  :having (see void/db/builder) plus :preload — the explicit, batched
  relation load. Returns an array of instances.``
  [ent &opt opts]
  (default opts {})
  (check-opts opts query-opts "db/query")
  (load-rows (resolve ent) opts))

(defn one
  "Like `query` with :limit 1 — the first matching entity or nil."
  [ent &opt opts]
  (default opts {})
  (first (query ent (merge opts {:limit 1}))))

(defn find
  ``Load one entity by primary key, or nil:

      (db/find User id)
      (db/find User id {:preload [:brand]})``
  [ent id &opt opts]
  (default opts {})
  (def desc (resolve ent))
  (or (when (nil? (get opts :preload)) (id-cache desc id))
      (one desc (merge opts {:where [:= [:col (desc :pk-column)] id]}))))

(defn find!
  "Like `find`, but throws when the row does not exist."
  [ent id &opt opts]
  (or (find ent id opts)
      (errorf "%q %q not found" ((resolve ent) :name) id)))

(defn count
  "How many rows match (no entity instances built). opts: :where."
  [ent &opt opts]
  (default opts {})
  (check-opts opts {:where true} "db/count")
  (def desc (resolve ent))
  (def stmt @{:select [[:raw "count(*) AS n"]] :from (desc :table)})
  (when-let [w (get opts :where)] (put stmt :where w))
  (or (state/value stmt) 0))

(defn exists?
  "Does any row match?"
  [ent &opt opts]
  (pos? (count ent opts)))

(defn rel
  ``Navigate a relation of a loaded instance:

      (db/rel u :brand)

  Preloaded relations are a table lookup. Anything else is an N+1 in
  the making: in dev it warns with the call site and loads the row, in
  :strict it throws (ADR-0009). Either way the fix is :preload.``
  [inst rname]
  (def desc (descriptor-of inst))
  (rel-of desc rname)
  (unless (preloaded? inst rname)
    (guard! desc rname)
    (load-preloads desc [inst] rname))
  (preloaded-value inst rname))

(defn preload!
  ``Preload relations onto already-loaded instances — the batched
  escape hatch when the rows came from somewhere else:

      (db/preload! User users [:brand])``
  [ent insts spec]
  (load-preloads (resolve ent) (if (indexed? insts) insts [insts]) spec)
  insts)

# -- writing -------------------------------------------------------------

(defn- reload-by-pk [desc id]
  (one desc {:where [:= [:col (desc :pk-column)] id]}))

(defn insert!
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
        (let [id (or (get attrs (desc :pk))
                     (when-let [f (drv :insert-id)] (f (entry :conn) res))
                     (get res :inserted-id))]
          (or (when id (reload-by-pk desc id))
              # no RETURNING and no id: hand back what was written
              (from-row desc row)))))))

(defn insert-all!
  "Insert several rows in one statement; returns the affected count."
  [ent rows]
  (def desc (resolve ent))
  (when (empty? rows) (break 0))
  (state/execute! {:insert (desc :table)
                   :values (tuple ;(map |(to-row desc $) rows))}))

(defn update!
  ``Patch a row by primary key; returns the number of rows written:

      (db/update! User id {:email "new@b.c"})``
  [ent id patch]
  (def desc (resolve ent))
  (when (empty? patch) (break 0))
  (state/execute! {:update (desc :table)
                   :set (to-row desc patch)
                   :where [:= [:col (desc :pk-column)] id]}))

(defn delete!
  "Delete a row by primary key; returns the number of rows deleted."
  [ent id]
  (def desc (resolve ent))
  (state/execute! {:delete (desc :table)
                   :where [:= [:col (desc :pk-column)] id]}))

(defn delete-where!
  "Delete every row matching a where clause; returns the count."
  [ent where]
  (def desc (resolve ent))
  (state/execute! {:delete (desc :table) :where where}))

(defn- refresh-snapshot! [inst]
  (def proto (table/getproto inst))
  (put proto :void.db/snapshot (own-values inst))
  inst)

(defn save!
  ``Write back the fields that changed since the instance was loaded —
  the AR half of ADR-0009, and nothing more:

      (-> u (put :email "x@y.z") (db/save!))

  A partial UPDATE of the diffed columns only; an unchanged instance
  writes nothing. With a :db/version field the UPDATE is guarded by
  the loaded version and a lost race throws instead of overwriting.
  Returns the instance with a refreshed snapshot.``
  [inst]
  (def desc (descriptor-of inst))
  (def diff (changes inst))
  (when (empty? diff) (break inst))
  (def id (get (snapshot inst) (desc :pk)))
  (when (nil? id)
    (errorf "%q has no primary key value — insert! it first" (desc :name)))
  (def vfield (desc :version))
  (def where
    (if vfield
      [:and
       [:= [:col (desc :pk-column)] id]
       [:= [:col (get-in desc [:fields vfield :column])]
        (get (snapshot inst) vfield)]]
      [:= [:col (desc :pk-column)] id]))
  (def to-write
    (if vfield
      (merge diff {vfield (inc (or (get (snapshot inst) vfield) 0))})
      diff))
  (def n (state/execute! {:update (desc :table)
                          :set (to-row desc to-write)
                          :where where}))
  (when (zero? n)
    (if vfield
      (errorf "%q %q was modified concurrently (version %q) — reload and retry"
              (desc :name) id (get (snapshot inst) vfield))
      (errorf "%q %q no longer exists — nothing was updated" (desc :name) id)))
  (when vfield (put inst vfield (get to-write vfield)))
  (refresh-snapshot! inst))

(defn reload
  "Re-read the instance from the database; returns a fresh instance."
  [inst &opt opts]
  (def desc (descriptor-of inst))
  (find desc (get (snapshot inst) (desc :pk)) opts))
