# Types of void/db's values, named where they recur.

# A row as a driver's :execute hands it back: keyword column keys, a table from the real drivers,
# a struct from a scripted one (a struct and a table are held to a shape by what they hold).
(def DbRow :typedef
  '{:keyword :any})

# What a driver's :execute answers (void/db/driver `result`, or the driver's own literal):
# the rows and the affected count, plus whatever the driver knows (postgres' :insert-oid).
(def DbResult :typedef
  '{:rows [DbRow] :count :number & r})

# The error a driver raises for a failed statement (the :void/db-driver contract), before the
# kernel's `driver/wrap-error` turns it into an envelope: plus :code, :constraint, :sql, ….
(def DbDriverError :typedef
  '{:db/error :keyword :message :string :sqlstate :string? & r})

# A :void/db-driver as a driver component's :start builds it: the four required keys, the
# optional ones `driver/normalize` falls back for, and anything of the driver's own — hence open.
(def DbDriver :typedef
  '{:dialect :keyword
    :connect (fn [] :any)
    :close (fn [:any] :any)
    :execute (fn [:any :string [:any] {:kind :keyword & r}] DbResult)
    :name :keyword?
    :returning :boolean?
    :prepare (or (fn [:any :string] :any) :nil)
    :execute-prepared (or DbExecutePrepared :nil)
    :begin (or (fn [:any :any] :any) :nil)
    :commit (or (fn [:any] :any) :nil)
    :rollback (or (fn [:any] :any) :nil)
    :savepoint (or (fn [:any :string] :any) :nil)
    :release-savepoint (or (fn [:any :string] :any) :nil)
    :rollback-to-savepoint (or (fn [:any :string] :any) :nil)
    :ping (or (fn [:any] :any) :nil)
    :insert-id (or (fn [:any DbResult] :any) :nil)
    :stream (or (fn [:any :string [:any] (fn [DbRow] :any)] :number) :nil)
    :reusable? (or (fn [:any] :boolean) :nil)
    & r})

# A driver's :execute-prepared: :execute over a statement its :prepare answered, not SQL text.
(def DbExecutePrepared :typedef
  '(fn [:any :any [:any] {:kind :keyword & r}] DbResult))

# A driver after `driver/normalize`: frozen, every fallback filled in so the kernel calls each key
# unconditionally, and :streams? derived. What the pool runs on and `db/driver` answers.
(def DbNormalizedDriver :typedef
  '{:name :keyword
    :dialect :keyword
    :connect (fn [] :any)
    :close (fn [:any] :any)
    :execute (fn [:any :string [:any] {:kind :keyword & r}] DbResult)
    :returning :boolean
    :prepare (or (fn [:any :string] :any) :nil)
    :execute-prepared (or DbExecutePrepared :nil)
    :ping (or (fn [:any] :any) :nil)
    :insert-id (or (fn [:any DbResult] :any) :nil)
    :stream (fn [:any :string [:any] (fn [DbRow] :any)] :number)
    :reusable? (fn [:any] :boolean)
    :begin (fn [:any :any] :any)
    :commit (fn [:any] :any)
    :rollback (fn [:any] :any)
    :savepoint (fn [:any :string] :any)
    :release-savepoint (fn [:any :string] :any)
    :rollback-to-savepoint (fn [:any :string] :any)
    :streams? :boolean
    & r})

# The connection pool of :db/pool: void/core/pool's pool, with the driver it runs on put under
# :driver by `pool/make`.
(def DbPool :typedef
  '@{:driver DbNormalizedDriver & r})

# One pooled connection (`pool/open-entry`): the raw connection and its prepared-statement cache.
# The pool and state add :idle-at, :owner and :discard as it is used — hence open.
(def DbPoolEntry :typedef
  '@{:conn :any :stmts @{:string :any} :id :number & r})

# A registered SQL dialect, as `builder/register-dialect!` builds it from a spec: the spec's
# functions and capability flags, each defaulted to what standard SQL says.
(def DbDialect :typedef
  '{:name :keyword
    :placeholder (fn [:number] :string)
    :quote (fn [:string] :string)
    :types {:keyword :string}
    :offset-needs-limit (or :string :boolean :nil)
    :backslash-escapes (or :boolean :nil)
    :index-if-not-exists :boolean
    :partial-indexes :boolean
    :row-locks :boolean
    :skip-locked :boolean
    :share-lock :string
    :upsert :keyword
    :advisory-lock DbAdvisoryLock?})

# A dialect's advisory lock: the statement that takes the named lock and the one that lets it go,
# plus, where the engine answers rather than blocks (MySQL's GET_LOCK), whether it was taken.
(def DbAdvisoryLock :typedef
  '{:acquire (fn [:any] DbSql) :release (fn [:any] DbSql)
    :acquired? (or (fn [[DbRow]] :boolean) :nil)})

# The context `builder/format` threads through compilation: the dialect and the parameters bound
# so far; a partial index's WHERE is compiled on a copy with :literals set.
(def DbCompileContext :typedef
  '@{:d DbDialect :params @[:any] :literals :boolean?})

# A statement map the builder compiles — {:select … :from …}, {:insert … :values …}, DDL — written
# by hand as a struct or grown as a table.
(def DbStatement :typedef
  '{:keyword :any})

# A compiled statement, as `builder/format` answers it and raw-SQL callers write it: [sql params].
(def DbSql :typedef
  '[:string [:any]])

# One field of an entity (entity.janet `field-map`): name, column, optionality, plus every :db/*
# prop the schema declares on it — hence open.
(def DbField :typedef
  '{:name :keyword :column :string :optional :boolean & r})

# One relation of an entity (entity.janet `rel-spec`): the normalized declaration, which keeps any
# further keys a map declaration carried — hence open.
(def DbRelation :typedef
  '{:name :keyword :kind :keyword :entity :keyword :key :keyword
    :through (or {:entity :keyword :key :keyword} :nil) & r})

# An entity descriptor, as `entity/descriptor` builds and freezes it: the mapping from a schema to
# a table that every repository call resolves through.
(def DbEntity :typedef
  '{:name :keyword
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
# the descriptor, the load-time snapshot and the preloaded relations.
(def DbInstance :typedef
  '@{:keyword :any})

# The options `entity/query`, `one`, `find` and `reload` accept — checked against this list, so
# closed; `one` and a preload merge them into a table, held to it the same.
(def DbQueryOptions :typedef
  '{:where :any :order-by :any :limit :any :offset :any :join :any :left-join :any
    :group-by :any :having :any :lock :any :preload :any :sql-opts :any
    :extra (or {:keyword :any} :nil)})

# A migration file found on disk (migrate.janet `files`).
(def DbMigration :typedef
  '@{:version :string :name :string :path :string})

# A migration file loaded (migrate.janet `load-migration`): its `up`, `down` and `transaction?`
# bindings read off the evaluated file.
(def DbLoadedMigration :typedef
  '@{:version :string :name :string :path :string
     :up (or (fn [] :any) :string :buffer @[:any] [:any] :nil)
     :down (or (fn [] :any) :string :buffer @[:any] [:any] :nil)
     :transaction? :boolean})

# -- drivers -------------------------------------------------------------

# A postgres prepared-statement catalogue (conn.janet `new-session`): name -> sql, and the
# counter names are minted from. It outlives a connection, so a replacement re-prepares under it.
(def PgSession :typedef
  '@{:stmts @{:string :string} :next :number})

# One NOTIFY as libpq delivers it: what a listener hands every handler of the channel.
(def PgNotification :typedef
  '{:channel :string :pid :number :payload :string})

# A live postgres connection: the table conn.janet `open` builds around the PGconn.
(def PgConn :typedef
  '@{:pg :pointer? :fds FdwaitPair :session PgSession
     :broken :boolean :closed :boolean :in-tx :boolean
     :conninfo :string :opts :any :decode :any
     :notifications @[PgNotification]
     :in-exchange :boolean})

# A pooled postgres handle (driver.janet `handle`): what a connection is made of, the live one,
# and the catalogue that outlives it.
(def PgHandle :typedef
  '@{:conninfo :string :open-opts :any :session PgSession :conn PgConn?
     :in-tx :boolean :generation :number :reconnect :boolean})

# What void/db-postgres answers for a connection it describes (`connection-info`): the live
# session's facts, or only its generation once the connection is gone.
(def PgConnectionInfo :typedef
  '(or {:server-version [:number :number] :backend-pid :number
        :transaction (enum :idle :active :in-transaction :in-error :unknown)
        :generation :number :prepared :number}
       {:generation :number :transaction :closed}))

# The postgres :void/db-driver (driver.janet `make`): the contract over a PgHandle, plus what
# callers that ask for Postgres by name reach (`:stream`, `:pipelined`, `:cancel!`,
# `:connection-info`). The prepared pair is there unless `:prepared false` left it off.
(def PgDriver :typedef
  '@{:name :keyword :dialect :keyword :returning :boolean :conninfo :string
     :connect (fn [] PgHandle)
     :close (fn [PgHandle] :nil)
     :execute (fn [PgHandle :string [:any] {:kind :keyword & r}] DbResult)
     :ping (fn [PgHandle] :any)
     :reusable? (fn [PgHandle] :boolean)
     :begin (fn [PgHandle :any] DbResult)
     :commit (fn [PgHandle] DbResult)
     :rollback (fn [PgHandle] DbResult)
     :savepoint (fn [PgHandle :string] DbResult)
     :release-savepoint (fn [PgHandle :string] DbResult)
     :rollback-to-savepoint (fn [PgHandle :string] DbResult)
     :stream (fn [PgHandle :string [:any] (fn [DbRow] :any)] :number)
     :pipelined (fn [PgHandle @[[:string (or [:any] :nil)]]] @[DbResult])
     :cancel! (fn [PgHandle] :boolean?)
     :connection-info (fn [PgHandle] PgConnectionInfo)
     :prepare (or (fn [PgHandle :string] :string) :nil)
     :execute-prepared (or DbExecutePrepared :nil)})

# The error void/db-postgres raises: the :void/db-driver envelope, plus whether the connection
# is gone with it.
(def PgError :typedef
  '{:db/error :keyword :message :string :fatal :boolean :sql :string? & r})

# The error void/db-mysql's worker answers for a failed call.
(def MysqlError :typedef
  '{:message :string :code :number :sqlstate :string :context :any :lost :boolean})
