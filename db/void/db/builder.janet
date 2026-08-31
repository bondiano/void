### void/db/builder — SQL as data (SPEC.md §5.9, ROADMAP 2.1).
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
### "count(*)"] passes SQL through untouched (no parameters). Dialects
### only differ in placeholder style and quoting and live in a registry
### so drivers (wave 2.2) can add their own.

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
  the driver contract.``
  [name spec]
  (unless (keyword? name)
    (errorf "dialect name must be a keyword, got %q" name))
  (def ph (get spec :placeholder))
  (unless (or (function? ph) (cfunction? ph))
    (errorf "dialect %q: :placeholder must be a function, got %q" name ph))
  (put dialect-registry name
       {:name name
        :placeholder ph
        :quote (get spec :quote quote-ansi)
        :types (merge ansi-types (get spec :types {}))})
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

(register-dialect! :ansi {:placeholder (fn [_] "?")})

(register-dialect! :sqlite
  {:placeholder (fn [_] "?")
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

# -- compilation context -------------------------------------------------

(defn- param! [ctx v]
  (array/push (ctx :params) (if (= null v) nil v))
  (((ctx :d) :placeholder) (length (ctx :params))))

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

(defn- val? [x]
  (and (indexed? x) (= :val (first x)) (= 2 (length x))))

(defn- value-str
  "A value position: always a parameter (or raw passthrough) — keywords
  here are data, not columns."
  [ctx v]
  (cond
    (raw? v) (raw-sql v)
    (val? v) (param! ctx (in v 1))
    (param! ctx v)))

(defn- operand
  "An operand of a binary operator: keyword = column, [:val x] = data,
  [:raw s] = passthrough, anything else a parameter."
  [ctx x]
  (cond
    (keyword? x) (ident (ctx :d) x)
    (raw? x) (raw-sql x)
    (val? x) (param! ctx (in x 1))
    (param! ctx x)))

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
  (unless (indexed? vals)
    (errorf "sql %q: values must be a tuple/array, got %q" (first c) vals))
  (if (empty? vals)
    (if negated "1 = 1" "1 = 0")
    (string (operand ctx col)
            (if negated " NOT IN (" " IN (")
            (string/join (map |(value-str ctx $) vals) ", ")
            ")")))

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
        :and (logical-str ctx "AND" (drop 1 c))
        :or (logical-str ctx "OR" (drop 1 c))
        :not (do (unless (= 2 (length c))
                   (errorf "sql :not expects one clause, got %q" c))
                 (string "NOT (" (clause ctx (in c 1)) ")"))
        :in (in-str ctx c false)
        :not-in (in-str ctx c true)
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
              (string/join (map |(string/format "%q" $) (sorted (keys allowed)))
                           " ")))))

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
  (when-let [n (get stmt :limit)]
    (unless (and (number? n) (= n (math/trunc n)) (>= n 0))
      (errorf "sql :limit must be a non-negative integer, got %q" n))
    (array/push out (string "LIMIT " (param! ctx n))))
  (when-let [n (get stmt :offset)]
    (unless (and (number? n) (= n (math/trunc n)) (>= n 0))
      (errorf "sql :offset must be a non-negative integer, got %q" n))
    (array/push out (string "OFFSET " (param! ctx n))))
  out)

# -- statements ----------------------------------------------------------

(def- select-keys
  {:select true :from true :join true :left-join true :where true
   :group-by true :having true :order-by true :limit true :offset true})

(defn- join-strs [ctx word pairs]
  (unless (indexed? pairs)
    (errorf "sql joins must be [[table on-clause] ...], got %q" pairs))
  (seq [p :in pairs]
    (unless (and (indexed? p) (= 2 (length p)))
      (errorf "sql join entry must be [table on-clause], got %q" p))
    (string word " " (ident (ctx :d) (first p)) " ON " (clause ctx (in p 1)))))

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
      (string "FROM " (ident (ctx :d) from))])
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
  (string/join parts " "))

(def- insert-keys {:insert true :values true :returning true})

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

(defn- literal
  "A DDL literal — a DEFAULT is part of the statement, not a parameter."
  [v]
  (cond
    (raw? v) (raw-sql v)
    (= null v) "NULL"
    (nil? v) "NULL"
    (boolean? v) (if v "TRUE" "FALSE")
    (number? v) (string v)
    (bytes? v) (string "'" (string/replace-all "'" "''" (string v)) "'")
    (errorf "sql DDL default must be a number, string, boolean or [:raw sql], got %q" v)))

(defn- type-str [d t]
  (cond
    (raw? t) (raw-sql t)
    (string? t) t
    (keyword? t)
    (or (get (d :types) t)
        (errorf "sql DDL: unknown column type %q for dialect %q (known: %s)"
                t (d :name)
                (string/join (map |(string/format "%q" $) (sorted (keys (d :types)))) " ")))
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
              (string/join (map |(string/format "%q" $) (sorted (keys column-opts))) " "))))
  (def parts @[(ident d cname) (type-str d ctype)])
  (when (get opts :primary-key) (array/push parts "PRIMARY KEY"))
  (when (= false (get opts :null)) (array/push parts "NOT NULL"))
  (when (get opts :unique) (array/push parts "UNIQUE"))
  # `has-key?`, not `(in opts :default)`: the value is what `in` returns
  # and `{:default false}` is exactly the declaration whose default
  # would then be dropped — silently, into a nullable column
  (when (has-key? opts :default)
    (array/push parts (string "DEFAULT " (literal (get opts :default)))))
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
  {:create-index true :on true :columns true :unique true :if-not-exists true})

(defn- compile-create-index [ctx stmt]
  (check-keys stmt create-index-keys ":create-index")
  (def d (ctx :d))
  (def cols (get stmt :columns))
  (unless (and (indexed? cols) (not (empty? cols)))
    (errorf "sql :create-index %q needs :columns" (stmt :create-index)))
  (string "CREATE " (if (get stmt :unique) "UNIQUE " "") "INDEX "
          (if (get stmt :if-not-exists) "IF NOT EXISTS " "")
          (ident d (stmt :create-index))
          " ON " (ident d (or (get stmt :on)
                              (errorf "sql :create-index %q needs :on"
                                      (stmt :create-index))))
          " (" (string/join (map |(ident d $) cols) ", ") ")"))

(def- drop-index-keys {:drop-index true :if-exists true :on true})

(defn- compile-drop-index [ctx stmt]
  (check-keys stmt drop-index-keys ":drop-index")
  (string "DROP INDEX "
          (if (get stmt :if-exists) "IF EXISTS " "")
          (ident (ctx :d) (stmt :drop-index))))

# -- entry point ---------------------------------------------------------

(defn format
  ``Compile a statement map into [sql params] for a dialect (a name or
  a dialect value; default :ansi). The statement kind is the map's
  head key: :select/:insert/:update/:delete for data,
  :create-table/:drop-table/:alter-table/:create-index/:drop-index for
  schema (which never has parameters).``
  [stmt &opt dialect-or-name]
  (unless (dictionary? stmt)
    (errorf "sql statement must be a map, got %q" stmt))
  (def d
    (cond
      (nil? dialect-or-name) (dialect :ansi)
      (keyword? dialect-or-name) (dialect dialect-or-name)
      dialect-or-name))
  (def ctx @{:params @[] :d d})
  (def sql
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
  [sql (tuple ;(ctx :params))])
