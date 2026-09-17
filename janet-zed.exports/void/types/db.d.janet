# Types of void/db's values, named where they recur.

# A row as a driver's :execute hands it back: keyword column keys, a table from the real drivers,
# a struct from a scripted one.
(def DbRow :typedef
  (or @{:keyword :any} {:keyword :any}))

# What a driver's :execute answers (void/db/driver `result`, or the driver's own literal):
# the rows and the affected count, plus whatever the driver knows (postgres' :insert-oid).
(def DbResult :typedef
  (or @{:rows (or @[DbRow] [DbRow]) :count :number & r}
      {:rows (or @[DbRow] [DbRow]) :count :number & r}))

# The error a driver raises for a failed statement (the :void/db-driver contract), before the
# kernel's `driver/wrap-error` turns it into an envelope: plus :code, :constraint, :sql, ….
(def DbDriverError :typedef
  {:db/error :keyword :message :string :sqlstate :string? & r})

# A :void/db-driver as a driver component's :start builds it: the four required keys, the
# optional ones `driver/normalize` falls back for, and anything of the driver's own — hence open.
(def DbDriver :typedef
  (or @{:dialect :keyword
        :connect (fn [] :any)
        :close (fn [:any] :any)
        :execute (fn [:any :string [:any] {:kind :keyword & r}] DbResult)
        :name :keyword?
        :returning :boolean?
        :prepare (or (fn [:any :string] :any) :nil)
        :execute-prepared (or :function :nil)
        :begin (or :function :nil)
        :commit (or :function :nil)
        :rollback (or :function :nil)
        :savepoint (or :function :nil)
        :release-savepoint (or :function :nil)
        :rollback-to-savepoint (or :function :nil)
        :ping (or (fn [:any] :any) :nil)
        :insert-id (or (fn [:any DbResult] :any) :nil)
        :stream (or (fn [:any :string [:any] (fn [DbRow] :any)] :number) :nil)
        :reusable? (or (fn [:any] :boolean) :nil)
        & r}
      {:dialect :keyword
       :connect (fn [] :any)
       :close (fn [:any] :any)
       :execute (fn [:any :string [:any] {:kind :keyword & r}] DbResult)
       :name :keyword?
       :returning :boolean?
       :prepare (or (fn [:any :string] :any) :nil)
       :execute-prepared (or :function :nil)
       :begin (or :function :nil)
       :commit (or :function :nil)
       :rollback (or :function :nil)
       :savepoint (or :function :nil)
       :release-savepoint (or :function :nil)
       :rollback-to-savepoint (or :function :nil)
       :ping (or (fn [:any] :any) :nil)
       :insert-id (or (fn [:any DbResult] :any) :nil)
       :stream (or (fn [:any :string [:any] (fn [DbRow] :any)] :number) :nil)
       :reusable? (or (fn [:any] :boolean) :nil)
       & r}))

# A driver after `driver/normalize`: frozen, every fallback filled in so the kernel calls each key
# unconditionally, and :streams? derived. What the pool runs on and `db/driver` answers.
(def DbNormalizedDriver :typedef
  {:name :keyword
   :dialect :keyword
   :connect (fn [] :any)
   :close (fn [:any] :any)
   :execute (fn [:any :string [:any] {:kind :keyword & r}] DbResult)
   :returning :boolean
   :prepare (or (fn [:any :string] :any) :nil)
   :execute-prepared (or :function :nil)
   :ping (or (fn [:any] :any) :nil)
   :insert-id (or (fn [:any DbResult] :any) :nil)
   :stream (fn [:any :string [:any] (fn [DbRow] :any)] :number)
   :reusable? (fn [:any] :boolean)
   :begin :function
   :commit :function
   :rollback :function
   :savepoint :function
   :release-savepoint :function
   :rollback-to-savepoint :function
   :streams? :boolean
   & r})

# The connection pool of :db/pool: void/core/pool's pool, with the driver it runs on put under
# :driver by `pool/make`.
(def DbPool :typedef
  @{:driver DbNormalizedDriver & r})

# One pooled connection (`pool/open-entry`): the raw connection and its prepared-statement cache.
# The pool and state add :idle-at, :owner and :discard as it is used — hence open.
(def DbPoolEntry :typedef
  @{:conn :any :stmts @{:string :any} :id :number & r})

# A registered SQL dialect, as `builder/register-dialect!` builds it from a spec: the spec's
# functions and capability flags, each defaulted to what standard SQL says.
(def DbDialect :typedef
  {:name :keyword
   :placeholder :function
   :quote :function
   :types {:keyword :string}
   :offset-needs-limit (or :string :boolean :nil)
   :backslash-escapes (or :boolean :nil)
   :index-if-not-exists :boolean
   :partial-indexes :boolean
   :row-locks :boolean
   :skip-locked :boolean
   :share-lock :string
   :upsert :keyword
   :advisory-lock (or {:acquire :function :release :function :acquired? :function? & r} :nil)})

# The context `builder/format` threads through compilation: the dialect and the parameters bound
# so far; a partial index's WHERE is compiled on a copy with :literals set.
(def DbCompileContext :typedef
  @{:d DbDialect :params @[:any] :literals :boolean?})

# A statement map the builder compiles — {:select … :from …}, {:insert … :values …}, DDL — written
# by hand as a struct or grown as a table.
(def DbStatement :typedef
  (or {:keyword :any} @{:keyword :any}))

# A compiled statement, as `builder/format` answers it and raw-SQL callers write it: [sql params].
(def DbSql :typedef
  [:string [:any]])

# One field of an entity (entity.janet `field-map`): name, column, optionality, plus every :db/*
# prop the schema declares on it — hence open.
(def DbField :typedef
  {:name :keyword :column :string :optional :boolean & r})

# One relation of an entity (entity.janet `rel-spec`): the normalized declaration, which keeps any
# further keys a map declaration carried — hence open.
(def DbRelation :typedef
  {:name :keyword :kind :keyword :entity :keyword :key :keyword
   :through (or {:entity :keyword :key :keyword} :nil) & r})

# An entity descriptor, as `entity/descriptor` builds and freezes it: the mapping from a schema to
# a table that every repository call resolves through.
(def DbEntity :typedef
  {:name :keyword
   :table :string
   :schema SchemaNode
   :pk :keyword
   :pk-column :string
   :version (or :keyword :nil)
   :fields {:keyword DbField}
   :columns [:string]
   :field-order [:keyword]
   :column->field {:keyword :keyword}
   :rels {:keyword DbRelation}})

# A loaded entity (entity.janet `from-row`): a plain table of column values whose prototype carries
# the descriptor, the load-time snapshot and the preloaded relations. (`:table` rather than
# `@{:any :any}`: janet-zed reads a named map-of type as a record whose one key is `:any`.)
(def DbInstance :typedef
  :table)

# The options `entity/query`, `one`, `find` and `reload` accept — checked against this list, so
# closed; `one` and a preload merge them into a table.
(def DbQueryOptions :typedef
  (or {:where :any :order-by :any :limit :any :offset :any :join :any :left-join :any
       :group-by :any :having :any :lock :any :preload :any :sql-opts :any
       :extra (or {:keyword :any} :nil)}
      @{:where :any :order-by :any :limit :any :offset :any :join :any :left-join :any
        :group-by :any :having :any :lock :any :preload :any :sql-opts :any
        :extra (or {:keyword :any} :nil)}))

# A migration file found on disk (migrate.janet `files`).
(def DbMigration :typedef
  @{:version :string :name :string :path :string})

# A migration file loaded (migrate.janet `load-migration`): its `up`, `down` and `transaction?`
# bindings read off the evaluated file.
(def DbLoadedMigration :typedef
  @{:version :string :name :string :path :string
    :up (or (fn [] :any) :string :buffer @[:any] [:any] :nil)
    :down (or (fn [] :any) :string :buffer @[:any] [:any] :nil)
    :transaction? :boolean})
