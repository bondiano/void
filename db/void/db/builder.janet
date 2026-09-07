### void/db/builder — SQL as data.
###
### honeysql-style: a statement is a plain map compiled per dialect
### into [sql params]:
###
###   {:select [:*] :from "users"
###    :where [:and [:= :brand-id 7] [:in :status ["active" "trial"]]]
###    :order-by [[:created-at :desc]] :limit 50}
###
### Identifier keywords are converted kebab/camel -> snake and quoted
### (:brand-id -> "brand_id", :users.id -> "users"."id"), everything
### else becomes a positional parameter. Inside binary operators BOTH
### sides follow identifier semantics — a keyword is a column, so join
### conditions read naturally; wrap data that happens to be a keyword
### with [:val :admin], or use the dictionary where-sugar / :set /
### :values maps, whose right-hand sides are always parameters. [:raw
### "count(*)"] passes SQL through untouched (no parameters), and [:sql
### "coalesce(n, ?)" [0]] is the same escape hatch with them: every `?`
### in the fragment becomes this dialect's placeholder in order, so a
### fragment written once compiles on `$n` engines too. A statement map
### in an operand position is a subquery. Dialects differ in
### placeholder style, quoting and a handful of named capabilities
### (partial indexes, row locks, the upsert spelling) and live in a
### registry so drivers can add their own.

(import void/core/util :as util)

(def null
  "Explicit SQL NULL for value positions — Janet dictionaries cannot
  hold nil, so {:set {:deleted-at db/null}} sets the column to NULL."
  :void.db/null)

(defn snake
  "Column/table spelling of an identifier: kebab and camel to snake —
  :brand-id -> \"brand_id\", :OrderItem -> \"order_item\"."
  [x]
  (def s (string x))
  (def b @"")
  (for i 0 (length s)
    (def c (s i))
    (cond
      (and (>= c 65) (<= c 90))
      (do (when (and (pos? i)
                     (not= 45 (s (dec i)))
                     (not= 95 (s (dec i))))
            (buffer/push-byte b 95))
          (buffer/push-byte b (+ c 32)))
      (= c 45) (buffer/push-byte b 95)
      (buffer/push-byte b c)))
  (string b))

# -- dialects ------------------------------------------------------------

(defn- quote-ansi [s]
  (string `"` (string/replace-all `"` `""` s) `"`))

(defn- quote-backtick [s]
  # MySQL's own quoting. `"` is an identifier quote there only under
  # the ANSI_QUOTES sql_mode and a string literal otherwise, so a
  # driver that quoted the ANSI way would compile differently
  # depending on a server setting; a backtick is one thing in both
  # modes.
  (string "`" (string/replace-all "`" "``" s) "`"))

(def- dialect-registry @{})

(def ansi-types
  ``The column types DDL statements are written in, and the SQL each
  one becomes. Migrations name a type here rather than a spelling, so
  the same declaration compiles on every engine; a dialect overrides
  the entries it disagrees with (:types), and [:raw "tsvector"] is the
  escape hatch for a type nobody but one engine has.``
  {:int "integer" :integer "integer" :smallint "smallint" :bigint "bigint"
   # an auto-numbering key: `[:id :serial {:primary-key true}]` is the
   # whole of it on both engines
   :serial "integer" :bigserial "bigint"
   :text "text" :string "text" :varchar "varchar"
   :bool "boolean" :boolean "boolean"
   :real "real" :double "double precision"
   :numeric "numeric" :decimal "numeric"
   :date "date" :time "time"
   :timestamp "timestamp" :timestamptz "timestamp with time zone"
   :json "json" :jsonb "json"
   :uuid "uuid" :blob "blob" :bytes "blob"})

(defn register-dialect!
  ``Register a dialect: {:placeholder (fn [n] str) :quote (fn [name] str)?
  :types {type-keyword sql-string}?}. The types are merged over
  `ansi-types`. Drivers name their dialect through the :dialect key of
  the driver contract.

  The capability flags below all default to what standard SQL says, so
  a dialect declares only its disagreements; each one names what the
  compiler does when the engine has not got the feature, because
  silently dropping a clause is only ever right when the clause was an
  optimisation.``
  [name spec]
  (unless (keyword? name)
    (errorf "dialect name must be a keyword, got %q" name))
  (def ph (get spec :placeholder))
  (unless (util/callable? ph)
    (errorf "dialect %q: :placeholder must be a function, got %q" name ph))
  (put dialect-registry name
       {:name name
        :placeholder ph
        :quote (get spec :quote quote-ansi)
        :types (merge ansi-types (get spec :types {}))
        # the one clause an engine can genuinely not express: see
        # `limit-str`
        :offset-needs-limit (get spec :offset-needs-limit)
        # does a backslash escape inside a string literal? MySQL's
        # default, and nobody else's — a DDL DEFAULT that quotes only
        # `'` would let a `\'` break out of the string (see `literal`)
        :backslash-escapes (get spec :backslash-escapes)
        # CREATE INDEX IF NOT EXISTS. Where it is missing the clause is
        # *dropped*, because it is pure spelling: the statement without
        # it does the same thing and fails with "index already there",
        # which an idempotent schema pass reads as done (see
        # void/db/driver's `duplicate-index?`)
        :index-if-not-exists (get spec :index-if-not-exists true)
        # a partial index (CREATE INDEX ... WHERE ...). Where it is
        # missing `:where` is *refused*, not dropped: an index over
        # fewer rows is an optimisation, but a UNIQUE one over fewer
        # rows is a different promise, and the compiler cannot tell
        # which one this is
        :partial-indexes (get spec :partial-indexes true)
        # SELECT ... FOR UPDATE. Where it is missing `:lock` is
        # dropped: an engine with no row locks is one whose writer is
        # serialized anyway (sqlite), and there the clause asks for
        # what the engine already gives
        :row-locks (get spec :row-locks true)
        # ... SKIP LOCKED. Dropped where missing, which leaves a
        # blocking FOR UPDATE — the claim waits instead of stepping
        # over the row, which is slower and not wrong
        :skip-locked (get spec :skip-locked true)
        # ... FOR SHARE. MySQL 8 took the standard spelling, MariaDB
        # never did, and one dialect serves both
        :share-lock (get spec :share-lock "FOR SHARE")
        # how an upsert is spelled: :on-conflict (Postgres, sqlite) or
        # :duplicate-key (MySQL's ON DUPLICATE KEY UPDATE)
        :upsert (get spec :upsert :on-conflict)})
  name)

(defn dialect
  "Fetch a registered dialect by name."
  [name]
  (or (get dialect-registry name)
      (errorf "unknown sql dialect %q (registered: %s)"
              name
              (string/join (map |(string/format "%q" $)
                                (sorted (keys dialect-registry)))
                           " "))))

(defn capability
  ``One flag of a dialect (see `register-dialect!`), by name: (sql/capability
  :mysql :partial-indexes) is false. What a plugin asks when the answer
  changes the statement it declares rather than the string that
  statement compiles to — a partial index is the case, and asking the
  capability is what keeps `(= :mysql dialect)` out of the plugins.``
  [dialect-name flag]
  (get (dialect dialect-name) flag))

(register-dialect! :ansi {:placeholder (fn [_] "?")})

(register-dialect! :sqlite
  {:placeholder (fn [_] "?")
   # one writer at a time, and the driver opens BEGIN IMMEDIATE: there
   # are no row locks because there is nothing to take one against
   :row-locks false
   :skip-locked false
   # sqlite has type affinity rather than types: `integer primary key`
   # is the rowid alias that numbers itself, and everything with no
   # affinity of its own is honestly text
   :types {:serial "integer" :bigserial "integer"
           :double "real" :timestamp "text" :timestamptz "text"
           :json "text" :jsonb "text" :uuid "text"}})

(register-dialect! :postgres
  {:placeholder (fn [n] (string "$" n))
   :types {:serial "serial" :bigserial "bigserial"
           :string "text" :jsonb "jsonb"
           :blob "bytea" :bytes "bytea"}})

# MySQL and MariaDB. The type table is where this engine disagrees with
# everyone else, and each entry below is a disagreement worth naming:
#
#   :string    varchar(255), not text — MySQL indexes a TEXT column
#              only with a prefix length, so `{:unique true}` on a
#              :string has to compile to something indexable. :text
#              stays TEXT and is the document you do not index; that
#              split is what having both names is for.
#   :varchar   also given a length: a bare `varchar` is a syntax error
#              here, and picking 255 beats failing at migrate time.
#   :serial    `int auto_increment`, deliberately NOT MySQL's own
#              SERIAL — that alias expands to BIGINT UNSIGNED NOT NULL
#              AUTO_INCREMENT UNIQUE, and the UNIQUE it hides would
#              collide with the PRIMARY KEY every declaration puts
#              next to it.
#   :timestamp datetime, :timestamptz timestamp. Inverted-looking and
#              correct: MySQL's TIMESTAMP is the one that normalizes
#              to UTC and converts back per session, which is what
#              timestamptz means; DATETIME is the wall clock, which is
#              what timestamp means.
#   :uuid      char(36). MySQL has no uuid type and MariaDB's is
#              10.7+, so the portable spelling is the text one.
#   :bool      MySQL's BOOLEAN is an alias for TINYINT(1) and the
#              server forgets which word you typed — see
#              void/db-mysql/types for the reading half of that.
(register-dialect! :mysql
  {:placeholder (fn [_] "?")
   :quote quote-backtick
   # `CREATE INDEX IF NOT EXISTS` is a syntax error here (MariaDB
   # takes it, MySQL does not, and one dialect serves both)
   :index-if-not-exists false
   # no partial indexes at all — the one thing on this list that is a
   # missing feature rather than a spelling
   :partial-indexes false
   # SKIP LOCKED landed in MySQL 8.0 and MariaDB 10.6, and the dialect
   # name says neither which engine nor which version is on the other
   # end of the socket; a blocking FOR UPDATE is the answer that is
   # right on all four
   :skip-locked false
   :share-lock "LOCK IN SHARE MODE"
   :upsert :duplicate-key
   # MySQL treats `\` as an escape inside a string literal (unless the
   # session runs NO_BACKSLASH_ESCAPES, which void/db-mysql refuses to
   # serve), so a DDL DEFAULT literal must double it — see `literal`
   :backslash-escapes true
   # `OFFSET 10` with no LIMIT is a syntax error, and MySQL's own
   # documented workaround is a LIMIT of the largest BIGINT UNSIGNED
   :offset-needs-limit "18446744073709551615"
   :types {:serial "int auto_increment" :bigserial "bigint auto_increment"
           :string "varchar(255)" :varchar "varchar(255)"
           :double "double" :real "float"
           :timestamp "datetime" :timestamptz "timestamp"
           :json "json" :jsonb "json"
           :uuid "char(36)" :bytes "blob"}})

# -- compilation context -------------------------------------------------

# set by the DDL section below: `literal` lives with the rest of the
# DDL, and a partial index is the one clause that is compiled into a
# statement which cannot carry parameters
(var- ddl-literal nil)

(defn- param! [ctx v]
  (if (get ctx :literals)
    (ddl-literal (ctx :d) v)
    (do
      (array/push (ctx :params) (if (= null v) nil v))
      (((ctx :d) :placeholder) (length (ctx :params))))))

(defn- quote-part [d s]
  (if (= s "*") "*" ((d :quote) s)))

(defn- ident [d x]
  (cond
    (string? x) ((d :quote) x)
    (keyword? x)
    (string/join (map |(quote-part d (snake $)) (string/split "." (string x)))
                 ".")
    (errorf "sql identifier must be a keyword or string, got %q" x)))

(defn- raw? [x]
  (and (indexed? x) (= :raw (first x))))

(defn- raw-sql [x]
  (unless (= 2 (length x))
    (errorf "[:raw sql] takes exactly one SQL string, got %q" x))
  (def s (in x 1))
  (unless (string? s)
    (errorf "[:raw sql]: sql must be a string, got %q" s))
  s)

(defn- sql? [x]
  (and (indexed? x) (= :sql (first x)) (or (= 2 (length x)) (= 3 (length x)))))

(defn- sql-fragment
  ``[:sql "n + ?" [1]] — hand-written SQL that still carries values.
  `[:raw]` with parameters, and the reason three plugins used to keep
  their own placeholder function: a fragment written with `?` is not
  portable to Postgres, where the placeholder is `$n` *and* n counts
  the parameters of the whole statement, not of the fragment. Here
  every `?` becomes this dialect's placeholder at this statement's
  position, so one fragment compiles on every engine.

  Which is also why a literal `?` cannot appear in the SQL — pass it
  as a parameter. A count that disagrees with the parameters is an
  error rather than an off-by-one discovered by the server.``
  [ctx x]
  (def s (in x 1))
  (unless (string? s)
    (errorf "[:sql sql params]: sql must be a string, got %q" s))
  (def params (get x 2 []))
  (unless (indexed? params)
    (errorf "[:sql sql params]: params must be a tuple/array, got %q" params))
  (def pieces (string/split "?" s))
  (unless (= (dec (length pieces)) (length params))
    (errorf "[:sql %q ...]: %d placeholder%s and %d parameter%s"
            s (dec (length pieces)) (if (= 1 (dec (length pieces))) "" "s")
            (length params) (if (= 1 (length params)) "" "s")))
  (def out @[(first pieces)])
  (for i 0 (length params)
    (array/push out (param! ctx (in params i)))
    (array/push out (in pieces (inc i))))
  (string ;out))

(defn- fragment? [x] (or (raw? x) (sql? x)))

(defn- fragment-str [ctx x]
  (if (raw? x) (raw-sql x) (sql-fragment ctx x)))

(def- statement-heads
  [:select :insert :update :delete :from
   :create-table :drop-table :alter-table :create-index :drop-index])

(defn- statement?
  ``Is this dictionary a statement — something with a head key — as
  opposed to a value that happens to be a map? The distinction is why
  a subquery is recognized in operand positions only: `{:set {:meta
  {...}}}` writes a map into a json column, and a compiler that read
  every map as a subquery would compile that into a syntax error.``
  [x]
  (and (dictionary? x)
       (truthy? (some |(not (nil? (get x $))) statement-heads))))

# set once the statement compilers below exist — a subquery is a
# statement in an operand position, and operands are compiled first
(var- compile-stmt nil)

(defn- subquery-str [ctx stmt]
  (string "(" (compile-stmt ctx stmt) ")"))

(defn- val? [x]
  (and (indexed? x) (= :val (first x)) (= 2 (length x))))

(defn- col? [x]
  (and (indexed? x) (= :col (first x)) (= 2 (length x))))

(defn- excluded? [x]
  (and (indexed? x) (= :excluded (first x)) (= 2 (length x))))

(defn- excluded-str
  ``The value the conflicting INSERT proposed, inside an upsert's SET —
  `excluded.col` where the upsert is ON CONFLICT, `VALUES(col)` on
  MySQL. The deprecated `VALUES()` rather than 8.0.19's row alias,
  because this dialect is MariaDB's too and the alias is not.``
  [ctx c]
  (def d (ctx :d))
  (if (= :duplicate-key (d :upsert))
    (string "VALUES(" (ident d c) ")")
    (string "excluded." (ident d c))))

(defn- value-str
  "A value position: always a parameter (or a SQL fragment) — keywords
  here are data, not columns, and so is a map (see `statement?`)."
  [ctx v]
  (cond
    (fragment? v) (fragment-str ctx v)
    (excluded? v) (excluded-str ctx (in v 1))
    (val? v) (param! ctx (in v 1))
    (param! ctx v)))

(defn- operand
  "An operand of a binary operator: keyword = column (snake-cased),
  [:col name] = an exact column identifier (quoted verbatim, no snake —
  how a caller names a column whose spelling is not snake_case), [:val x]
  = data, [:raw s] / [:sql s params] = passthrough, a statement map = a
  subquery, anything else a parameter."
  [ctx x]
  (cond
    (keyword? x) (ident (ctx :d) x)
    (col? x) (ident (ctx :d) (string (in x 1)))
    (excluded? x) (excluded-str ctx (in x 1))
    (fragment? x) (fragment-str ctx x)
    (val? x) (param! ctx (in x 1))
    (statement? x) (subquery-str ctx x)
    (param! ctx x)))

(defn- table-str
  ``A table position: a name, [name :alias], or [statement :alias] —
  the derived table, which every engine wants a name for. [:raw ...]
  passes through, for the table-valued functions no two engines
  spell alike.``
  [ctx x]
  (cond
    (fragment? x) (fragment-str ctx x)
    (or (keyword? x) (string? x)) (ident (ctx :d) x)
    (and (indexed? x) (= 2 (length x)))
    (let [[src alias] x]
      (string (if (statement? src) (subquery-str ctx src) (ident (ctx :d) src))
              " AS " (ident (ctx :d) alias)))
    (statement? x)
    (errorf "sql: a subquery in a table position needs an alias — [<statement> :alias], got %q" x)
    (errorf "sql table must be a name, [name :alias] or [statement :alias], got %q" x)))

# -- where clauses -------------------------------------------------------

(def- cmp-ops
  {:= "=" :<> "<>" :!= "<>" :< "<" :<= "<=" :> ">" :>= ">="
   :like "LIKE" :ilike "ILIKE"})

(var- clause nil)

(defn- null-value? [v]
  (or (nil? v) (= null v)))

(defn- eq-str [ctx k v]
  (if (null-value? v)
    (string (operand ctx k) " IS NULL")
    (string (operand ctx k) " = " (value-str ctx v))))

(defn- in-str [ctx c negated]
  (unless (= 3 (length c))
    (errorf "sql %q expects [%q column values], got %q" (first c) (first c) c))
  (def [_ col vals] c)
  # IN over a subquery: the values are the rows of another statement,
  # and the empty-list answer below has no equivalent — an IN over a
  # SELECT that returns nothing is already false
  (when (statement? vals)
    (break (string (operand ctx col)
                   (if negated " NOT IN " " IN ")
                   (subquery-str ctx vals))))
  (unless (indexed? vals)
    (errorf "sql %q: values must be a tuple/array or a statement, got %q" (first c) vals))
  (if (empty? vals)
    (if negated "1 = 1" "1 = 0")
    (string (operand ctx col)
            (if negated " NOT IN (" " IN (")
            (string/join (map |(value-str ctx $) vals) ", ")
            ")")))

(defn- exists-str [ctx c negated]
  (unless (= 2 (length c))
    (errorf "sql %q expects [%q statement], got %q" (first c) (first c) c))
  (def sub (in c 1))
  (unless (statement? sub)
    (errorf "sql %q: expects a statement map, got %q" (first c) sub))
  (string (if negated "NOT EXISTS " "EXISTS ") (subquery-str ctx sub)))

(defn- logical-str [ctx word cs]
  (when (empty? cs)
    (errorf "sql %q needs at least one clause" word))
  (if (= 1 (length cs))
    (clause ctx (first cs))
    (string "(" (string/join (map |(clause ctx $) cs) (string " " word " ")) ")")))

(defn- cmp-str [ctx c]
  (def [op a b] c)
  (unless (= 3 (length c))
    (errorf "sql %q expects [%q a b], got %q" op op c))
  (cond
    (and (= "=" (cmp-ops op)) (null-value? b))
    (string (operand ctx a) " IS NULL")
    (and (= "<>" (cmp-ops op)) (null-value? b))
    (string (operand ctx a) " IS NOT NULL")
    (string (operand ctx a) " " (cmp-ops op) " " (operand ctx b))))

(set clause
  (fn clause [ctx c]
    (cond
      (dictionary? c)
      (do (when (empty? c)
            (error "sql: an empty dictionary is not a where clause"))
          (string/join (seq [k :in (sorted (keys c))]
                         (eq-str ctx k (c k)))
                       " AND "))

      (and (indexed? c) (keyword? (first c)))
      (case (first c)
        :raw (raw-sql c)
        :sql (sql-fragment ctx c)
        :and (logical-str ctx "AND" (drop 1 c))
        :or (logical-str ctx "OR" (drop 1 c))
        :not (do (unless (= 2 (length c))
                   (errorf "sql :not expects one clause, got %q" c))
                 (string "NOT (" (clause ctx (in c 1)) ")"))
        :in (in-str ctx c false)
        :not-in (in-str ctx c true)
        :exists (exists-str ctx c false)
        :not-exists (exists-str ctx c true)
        :between
        (do (unless (= 4 (length c))
              (errorf "sql :between expects [:between column lo hi], got %q" c))
            (string (operand ctx (in c 1)) " BETWEEN "
                    (value-str ctx (in c 2)) " AND " (value-str ctx (in c 3))))
        (if (in cmp-ops (first c))
          (cmp-str ctx c)
          (errorf "sql: unknown clause operator %q in %q" (first c) c)))

      (errorf "sql: cannot compile where clause %q" c))))

# -- shared statement pieces ---------------------------------------------

(defn- check-keys [stmt allowed what]
  (eachk k stmt
    (unless (in allowed k)
      (errorf "sql %s: unknown key %q (allowed: %s)"
              what k
              (util/names-str (keys allowed))))))

(defn- where-str [ctx stmt]
  (when-let [w (get stmt :where)]
    (string "WHERE " (clause ctx w))))

(defn- returning-str [ctx r]
  (when r
    (def cols
      (cond
        (= true r) "*"
        (indexed? r) (string/join (map |(operand ctx $) r) ", ")
        (errorf "sql :returning must be true or a tuple of columns, got %q" r)))
    (string "RETURNING " cols)))

(defn- order-str [ctx items]
  (when items
    (unless (indexed? items)
      (errorf "sql :order-by must be a tuple, got %q" items))
    (string "ORDER BY "
            (string/join
              (seq [it :in items]
                (cond
                  (keyword? it) (ident (ctx :d) it)
                  (and (indexed? it) (= 2 (length it)))
                  (do (def [col dir] it)
                      (unless (in {:asc "ASC" :desc "DESC"} dir)
                        (errorf "sql :order-by direction must be :asc or :desc, got %q" dir))
                      (string (ident (ctx :d) col) " "
                              (if (= :desc dir) "DESC" "ASC")))
                  (errorf "sql :order-by entry must be a column or [column :asc|:desc], got %q" it)))
              ", "))))

(defn- limit-str [ctx stmt]
  (def out @[])
  (defn count! [k]
    (when-let [n (get stmt k)]
      (unless (and (number? n) (= n (math/trunc n)) (>= n 0))
        (errorf "sql %q must be a non-negative integer, got %q" k n))
      n))
  (def limit (count! :limit))
  (def offset (count! :offset))
  (cond
    limit (array/push out (string "LIMIT " (param! ctx limit)))
    # an OFFSET with no LIMIT is a syntax error on MySQL, and the
    # dialect carries the largest-BIGINT LIMIT its manual prescribes.
    # A literal, not a parameter: it is the dialect's own SQL, not the
    # caller's data
    (and offset (get (ctx :d) :offset-needs-limit))
    (array/push out (string "LIMIT " ((ctx :d) :offset-needs-limit))))
  (when offset (array/push out (string "OFFSET " (param! ctx offset))))
  out)

# -- statements ----------------------------------------------------------

(def- select-keys
  {:select true :from true :join true :left-join true :where true
   :group-by true :having true :order-by true :limit true :offset true
   :lock true})

(def- lock-modes {:update true :share true})

(def- lock-opts {:mode true :skip-locked true})

(defn- lock-str
  ``The row lock a claim takes: `:lock :update` (FOR UPDATE), or
  `:lock {:mode :update :skip-locked true}`. Both halves fall back
  rather than fail: an engine with no row locks drops the clause (its
  writer is serialized, which is what the lock was asking for), and
  one without SKIP LOCKED keeps a blocking FOR UPDATE, which waits
  where it would have stepped over the row. Both fallbacks live in the
  dialect, so the caller writes the claim once.``
  [ctx stmt]
  (when-let [l (get stmt :lock)]
    (def d (ctx :d))
    (def spec
      (cond
        (keyword? l) {:mode l}
        (dictionary? l) l
        (errorf "sql :lock must be a mode keyword or a map, got %q" l)))
    (eachk k spec
      (unless (in lock-opts k)
        (errorf "sql :lock: unknown option %q (allowed: %s)"
                k (util/names-str (keys lock-opts)))))
    (def mode (get spec :mode :update))
    (unless (in lock-modes mode)
      (errorf "sql :lock :mode must be :update or :share, got %q" mode))
    (when (d :row-locks)
      (string (if (= :share mode) (d :share-lock) "FOR UPDATE")
              (if (and (get spec :skip-locked) (d :skip-locked))
                " SKIP LOCKED"
                "")))))

(defn- join-strs [ctx word pairs]
  (unless (indexed? pairs)
    (errorf "sql joins must be [[table on-clause] ...], got %q" pairs))
  (seq [p :in pairs]
    (unless (and (indexed? p) (= 2 (length p)))
      (errorf "sql join entry must be [table on-clause], got %q" p))
    (string word " " (table-str ctx (first p)) " ON " (clause ctx (in p 1)))))

(defn- compile-select [ctx stmt]
  (check-keys stmt select-keys ":select")
  (def from (or (get stmt :from)
                (error "sql :select needs a :from table")))
  (def cols (get stmt :select))
  (def parts
    @[(string "SELECT "
              (if (or (nil? cols) (empty? cols) (deep= cols [:*]))
                "*"
                (string/join (map |(operand ctx $) cols) ", ")))
      (string "FROM " (table-str ctx from))])
  (array/concat parts (join-strs ctx "JOIN" (get stmt :join [])))
  (array/concat parts (join-strs ctx "LEFT JOIN" (get stmt :left-join [])))
  (when-let [w (where-str ctx stmt)] (array/push parts w))
  (when-let [g (get stmt :group-by)]
    (array/push parts (string "GROUP BY "
                              (string/join (map |(ident (ctx :d) $) g) ", "))))
  (when-let [h (get stmt :having)]
    (array/push parts (string "HAVING " (clause ctx h))))
  (when-let [o (order-str ctx (get stmt :order-by))] (array/push parts o))
  (array/concat parts (limit-str ctx stmt))
  (when-let [l (lock-str ctx stmt)] (array/push parts l))
  (string/join parts " "))

(def- insert-keys
  {:insert true :values true :returning true :on-conflict true})

(def- on-conflict-keys {:on true :set true :where true})

(defn- on-conflict-str
  ``The upsert: `:on-conflict :nothing`, or a map — {:on [:id] :set
  {:n [:sql "n + ?" [1]]} :where [...]}. `:set` is what makes it a DO
  UPDATE; without it the row is dropped. `[:excluded :col]` is the
  value the losing INSERT proposed.

  Two engines, two spellings and one genuine difference. ON CONFLICT
  wants the conflict target named (Postgres refuses a DO UPDATE
  without one) and takes a condition; ON DUPLICATE KEY UPDATE fires on
  *any* unique index and takes no condition, so `:on` is documentation
  there and `:where` is refused rather than silently dropped — a
  condition that does not run is a row updated when it should not
  have been.

  DO NOTHING on MySQL is a column set to itself, which is the same
  no-op without INSERT IGNORE's habit of swallowing every other error
  too.``
  [ctx spec cols]
  (def d (ctx :d))
  (def oc
    (cond
      (= :nothing spec) {}
      (dictionary? spec) spec
      (errorf "sql :on-conflict must be :nothing or a map, got %q" spec)))
  (eachk k oc
    (unless (in on-conflict-keys k)
      (errorf "sql :on-conflict: unknown key %q (allowed: %s)"
              k (util/names-str (keys on-conflict-keys)))))
  (def target (get oc :on))
  (when target
    (unless (and (indexed? target) (not (empty? target)))
      (errorf "sql :on-conflict :on must be a non-empty tuple of columns, got %q" target)))
  (def sets (get oc :set))
  (when sets
    (unless (and (dictionary? sets) (not (empty? sets)))
      (errorf "sql :on-conflict :set must be a non-empty map, got %q" sets)))
  (def where (get oc :where))
  (defn assignments []
    (string/join (seq [k :in (sorted (keys sets))]
                   (string (ident d k) " = " (value-str ctx (get sets k))))
                 ", "))
  (if (= :duplicate-key (d :upsert))
    (do
      (when where
        (errorf (string "sql :on-conflict :where: dialect %q updates on any "
                        "unique key and takes no condition — put the condition "
                        "in the :set values, or branch on the dialect")
                (d :name)))
      (string "ON DUPLICATE KEY UPDATE "
              (if sets
                (assignments)
                # the no-op: a column set to itself. The conflict
                # target names it when there is one, the first inserted
                # column otherwise — either way it is a column this
                # statement is certainly writing
                (let [c (if target (first target) (first cols))]
                  (string (ident d c) " = " (ident d c))))))
    (do
      (when (and sets (not target))
        (error (string "sql :on-conflict: a DO UPDATE needs :on — the conflict "
                       "target is what Postgres decides the arbiter index by")))
      (string "ON CONFLICT "
              (if target
                (string "(" (string/join (map |(ident d $) target) ", ") ") ")
                "")
              (if sets
                (string "DO UPDATE SET " (assignments)
                        (if where (string " WHERE " (clause ctx where)) ""))
                "DO NOTHING")))))

(defn- compile-insert [ctx stmt]
  (check-keys stmt insert-keys ":insert")
  (def rows
    (let [v (or (get stmt :values)
                (error "sql :insert needs :values"))]
      (cond
        (dictionary? v) [v]
        (indexed? v) (do (when (empty? v)
                           (error "sql :insert :values must not be empty"))
                         v)
        (errorf "sql :insert :values must be a row map or a tuple of row maps, got %q" v))))
  (def cols (sorted (keys (first rows))))
  (when (empty? cols)
    (error "sql :insert: a row map must not be empty"))
  (each row rows
    (unless (deep= (sorted (keys row)) cols)
      (errorf "sql :insert: every row must have the same keys (expected %q, got %q)"
              cols (sorted (keys row)))))
  (def parts
    @[(string "INSERT INTO " (ident (ctx :d) (stmt :insert))
              " (" (string/join (map |(ident (ctx :d) $) cols) ", ") ")")
      (string "VALUES "
              (string/join
                (seq [row :in rows]
                  (string "(" (string/join (seq [c :in cols]
                                             (value-str ctx (row c)))
                                           ", ")
                          ")"))
                ", "))])
  (when-let [oc (get stmt :on-conflict)]
    (array/push parts (on-conflict-str ctx oc cols)))
  (when-let [r (returning-str ctx (get stmt :returning))] (array/push parts r))
  (string/join parts " "))

(def- update-keys {:update true :set true :where true :returning true})

(defn- compile-update [ctx stmt]
  (check-keys stmt update-keys ":update")
  (def sets (or (get stmt :set)
                (error "sql :update needs :set")))
  (unless (and (dictionary? sets) (not (empty? sets)))
    (errorf "sql :update :set must be a non-empty map, got %q" sets))
  (def parts
    @[(string "UPDATE " (ident (ctx :d) (stmt :update)))
      (string "SET "
              (string/join (seq [k :in (sorted (keys sets))]
                             (string (ident (ctx :d) k) " = "
                                     (value-str ctx (sets k))))
                           ", "))])
  (when-let [w (where-str ctx stmt)] (array/push parts w))
  (when-let [r (returning-str ctx (get stmt :returning))] (array/push parts r))
  (string/join parts " "))

(def- delete-keys {:delete true :where true :returning true})

(defn- compile-delete [ctx stmt]
  (check-keys stmt delete-keys ":delete")
  (def parts @[(string "DELETE FROM " (ident (ctx :d) (stmt :delete)))])
  (when-let [w (where-str ctx stmt)] (array/push parts w))
  (when-let [r (returning-str ctx (get stmt :returning))] (array/push parts r))
  (string/join parts " "))

# -- DDL -----------------------------------------------------------------
#
# The same idea one level down: a migration says what the table is, not
# how this engine spells it. Types come from the dialect's table
# (`ansi-types` plus its overrides), so `[:id :serial {:primary-key
# true}]` is `"id" integer PRIMARY KEY` on sqlite and `"id" serial
# PRIMARY KEY` on Postgres — the dialect `if` that every hand-written
# migration grows is written once, here.
#
# DDL takes no parameters: a DEFAULT is part of the statement, not a
# bind value, so defaults render as literals and `format` hands back an
# empty parameter tuple.

(def- referential-actions
  {:cascade "CASCADE" :restrict "RESTRICT" :set-null "SET NULL"
   :set-default "SET DEFAULT" :no-action "NO ACTION"})

(defn- quote-string-literal
  ``A string as a DDL literal. `'` doubles everywhere; `\` doubles too
  on a dialect that treats it as an escape (MySQL) — otherwise a value
  like `a\'` closes the string one character early and the tail becomes
  bare SQL.``
  [d s]
  (def escaped
    (if (get d :backslash-escapes)
      (string/replace-all "'" "''" (string/replace-all `\` `\\` s))
      (string/replace-all "'" "''" s)))
  (string "'" escaped "'"))

(defn- literal
  "A DDL literal — a DEFAULT is part of the statement, not a parameter."
  [d v]
  (cond
    (raw? v) (raw-sql v)
    (= null v) "NULL"
    (nil? v) "NULL"
    (boolean? v) (if v "TRUE" "FALSE")
    (number? v) (string v)
    (bytes? v) (quote-string-literal d (string v))
    (errorf "sql DDL default must be a number, string, boolean or [:raw sql], got %q" v)))

(set ddl-literal literal)

(defn- type-str [d t]
  (cond
    (raw? t) (raw-sql t)
    (string? t) t
    (keyword? t)
    (or (get (d :types) t)
        (errorf "sql DDL: unknown column type %q for dialect %q (known: %s)"
                t (d :name)
                (util/names-str (keys (d :types)))))
    (errorf "sql DDL column type must be a keyword, a string or [:raw sql], got %q" t)))

(def- column-opts
  {:primary-key true :null true :unique true :default true
   :refs true :on-delete true :on-update true})

(defn- references-str [d opts]
  (when-let [r (get opts :refs)]
    (def [table column]
      (cond
        (or (keyword? r) (string? r)) [r :id]
        (and (indexed? r) (= 2 (length r))) [(r 0) (r 1)]
        (errorf "sql DDL :refs must be a table or [table column], got %q" r)))
    (def parts
      @[(string "REFERENCES " (ident d table) " (" (ident d column) ")")])
    (each [k word] [[:on-delete "ON DELETE"] [:on-update "ON UPDATE"]]
      (when-let [a (get opts k)]
        (array/push parts
                    (string word " "
                            (or (referential-actions a)
                                (errorf "sql DDL %q must be one of %s, got %q"
                                        k
                                        (string/join (map |(string/format "%q" $)
                                                          (sorted (keys referential-actions)))
                                                     " ")
                                        a))))))
    (string/join parts " ")))

(defn- column-str
  ``One column of a :create-table (or the argument of an :add-column):
  [name type] or [name type {opts}].``
  [d col]
  (unless (and (indexed? col) (or (= 2 (length col)) (= 3 (length col))))
    (errorf "sql DDL column must be [name type] or [name type opts], got %q" col))
  (def [cname ctype] col)
  (def opts (get col 2 {}))
  (unless (dictionary? opts)
    (errorf "sql DDL column %q: options must be a map, got %q" cname opts))
  (eachk k opts
    (unless (in column-opts k)
      (errorf "sql DDL column %q: unknown option %q (allowed: %s)"
              cname k
              (util/names-str (keys column-opts)))))
  (def parts @[(ident d cname) (type-str d ctype)])
  (when (get opts :primary-key) (array/push parts "PRIMARY KEY"))
  (when (= false (get opts :null)) (array/push parts "NOT NULL"))
  (when (get opts :unique) (array/push parts "UNIQUE"))
  # `has-key?`, not `(in opts :default)`: the value is what `in` returns
  # and `{:default false}` is exactly the declaration whose default
  # would then be dropped — silently, into a nullable column
  (when (has-key? opts :default)
    (array/push parts (string "DEFAULT " (literal d (get opts :default)))))
  (when-let [r (references-str d opts)] (array/push parts r))
  (string/join parts " "))

(def- create-table-keys
  {:create-table true :columns true :if-not-exists true :primary-key true})

(defn- compile-create-table [ctx stmt]
  (check-keys stmt create-table-keys ":create-table")
  (def d (ctx :d))
  (def cols (get stmt :columns))
  (unless (and (indexed? cols) (not (empty? cols)))
    (errorf "sql :create-table %q needs :columns" (stmt :create-table)))
  (def lines (map |(column-str d $) cols))
  (when-let [pk (get stmt :primary-key)]
    (unless (indexed? pk)
      (errorf "sql :create-table :primary-key must be a tuple of columns, got %q" pk))
    (array/push lines
                (string "PRIMARY KEY (" (string/join (map |(ident d $) pk) ", ") ")")))
  (string "CREATE TABLE "
          (if (get stmt :if-not-exists) "IF NOT EXISTS " "")
          (ident d (stmt :create-table))
          " (\n  " (string/join lines ",\n  ") "\n)"))

(def- drop-table-keys {:drop-table true :if-exists true :cascade true})

(defn- compile-drop-table [ctx stmt]
  (check-keys stmt drop-table-keys ":drop-table")
  (string "DROP TABLE "
          (if (get stmt :if-exists) "IF EXISTS " "")
          (ident (ctx :d) (stmt :drop-table))
          (if (get stmt :cascade) " CASCADE" "")))

(def- alter-table-keys
  {:alter-table true :add-column true :drop-column true
   :rename-column true :rename-to true})

(defn- compile-alter-table [ctx stmt]
  (check-keys stmt alter-table-keys ":alter-table")
  (def d (ctx :d))
  (def head (string "ALTER TABLE " (ident d (stmt :alter-table)) " "))
  (def actions
    (filter identity
      [(when-let [c (get stmt :add-column)]
         (string "ADD COLUMN " (column-str d c)))
       (when-let [c (get stmt :drop-column)]
         (string "DROP COLUMN " (ident d c)))
       (when-let [r (get stmt :rename-column)]
         (unless (and (indexed? r) (= 2 (length r)))
           (errorf "sql :alter-table :rename-column must be [from to], got %q" r))
         (string "RENAME COLUMN " (ident d (r 0)) " TO " (ident d (r 1))))
       (when-let [t (get stmt :rename-to)]
         (string "RENAME TO " (ident d t)))]))
  (unless (= 1 (length actions))
    (errorf (string "sql :alter-table %q takes exactly one of :add-column "
                    ":drop-column :rename-column :rename-to (got %d) — one "
                    "statement per change, because that is what the engines do")
            (stmt :alter-table) (length actions)))
  (string head (first actions)))

(def- create-index-keys
  {:create-index true :on true :columns true :unique true :if-not-exists true
   :where true})

(defn- compile-create-index [ctx stmt]
  (check-keys stmt create-index-keys ":create-index")
  (def d (ctx :d))
  (def cols (get stmt :columns))
  (unless (and (indexed? cols) (not (empty? cols)))
    (errorf "sql :create-index %q needs :columns" (stmt :create-index)))
  (def where (get stmt :where))
  (when (and where (not (d :partial-indexes)))
    (errorf (string "sql :create-index %q: dialect %q has no partial indexes. "
                    "A plain index over the same columns is the same promise "
                    "when the predicate is only about NULLs (a NULL is distinct "
                    "from every other NULL in a unique index); otherwise the two "
                    "are different indexes and the choice is the caller's")
            (stmt :create-index) (d :name)))
  (string "CREATE " (if (get stmt :unique) "UNIQUE " "") "INDEX "
          # dropped where the engine has not got it: the bare statement
          # does the same thing and answers "already there", which is
          # what an idempotent schema pass reads as done
          (if (and (get stmt :if-not-exists) (d :index-if-not-exists))
            "IF NOT EXISTS "
            "")
          (ident d (stmt :create-index))
          " ON " (ident d (or (get stmt :on)
                              (errorf "sql :create-index %q needs :on"
                                      (stmt :create-index))))
          " (" (string/join (map |(ident d $) cols) ", ") ")"
          # DDL carries no parameters, so the predicate's values render
          # as literals — the same rule a DEFAULT follows
          (if where
            (string " WHERE " (clause (merge (table ;(kvs ctx)) @{:literals true})
                                      where))
            "")))

(def- drop-index-keys {:drop-index true :if-exists true :on true})

(defn- compile-drop-index [ctx stmt]
  (check-keys stmt drop-index-keys ":drop-index")
  (string "DROP INDEX "
          (if (get stmt :if-exists) "IF EXISTS " "")
          (ident (ctx :d) (stmt :drop-index))))

# -- composing where clauses ---------------------------------------------
#
# A statement is data, so a query built in pieces is data being built
# in pieces — but the pieces are usually conditional, and `(if q [:=
# :queue q] ...)` inside an `[:and ...]` puts a nil where a clause has
# to be. These two skip the nils; a partial query is then a statement
# whose :where is extended as the conditions are learned.

(defn all-of
  ``The clauses that are there, ANDed: nil arguments are skipped, one
  clause is itself, none is nil (which is what `:where` reads as "no
  condition").``
  [& clauses]
  (def cs (filter |(not (nil? $)) clauses))
  (case (length cs)
    0 nil
    1 (first cs)
    [:and ;cs]))

(defn any-of
  "The clauses that are there, ORed — see `all-of`."
  [& clauses]
  (def cs (filter |(not (nil? $)) clauses))
  (case (length cs)
    0 nil
    1 (first cs)
    [:or ;cs]))

(defn and-where
  ``A statement with `clause` ANDed onto its :where — the way a partial
  statement grows a condition. A nil clause leaves the statement
  alone, so a caller can hand the result of a `when` straight in.``
  [stmt clause]
  (if (nil? clause)
    stmt
    (merge (table ;(kvs stmt)) {:where (all-of (get stmt :where) clause)})))

# -- entry point ---------------------------------------------------------

(defn- compile-statement
  "The dispatch on a statement's head key — also what a subquery in an
  operand position is compiled with."
  [ctx stmt]
  (unless (dictionary? stmt)
    (errorf "sql statement must be a map, got %q" stmt))
  (cond
    (get stmt :select) (compile-select ctx stmt)
    (get stmt :insert) (compile-insert ctx stmt)
    (get stmt :update) (compile-update ctx stmt)
    (get stmt :delete) (compile-delete ctx stmt)
    (get stmt :create-table) (compile-create-table ctx stmt)
    (get stmt :drop-table) (compile-drop-table ctx stmt)
    (get stmt :alter-table) (compile-alter-table ctx stmt)
    (get stmt :create-index) (compile-create-index ctx stmt)
    (get stmt :drop-index) (compile-drop-index ctx stmt)
    # a bare {:from ...} still reads as a select
    (get stmt :from) (compile-select ctx stmt)
    (errorf (string "sql: statement %q has no head key "
                    "(:select :insert :update :delete :create-table "
                    ":drop-table :alter-table :create-index :drop-index)")
            stmt)))

(set compile-stmt compile-statement)

(defn format
  ``Compile a statement map into [sql params] for a dialect (a name or
  a dialect value; default :ansi). The statement kind is the map's
  head key: :select/:insert/:update/:delete for data,
  :create-table/:drop-table/:alter-table/:create-index/:drop-index for
  schema (which never has parameters).``
  [stmt &opt dialect-or-name]
  (def d
    (cond
      (nil? dialect-or-name) (dialect :ansi)
      (keyword? dialect-or-name) (dialect dialect-or-name)
      dialect-or-name))
  (def ctx @{:params @[] :d d})
  (def sql (compile-statement ctx stmt))
  [sql (tuple ;(ctx :params))])
