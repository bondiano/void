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

(defn register-dialect!
  "Register a dialect: {:placeholder (fn [n] str) :quote (fn [name] str)?}.
  Drivers name theirs through the :dialect key of the driver contract."
  [name spec]
  (unless (keyword? name)
    (errorf "dialect name must be a keyword, got %q" name))
  (def ph (get spec :placeholder))
  (unless (or (function? ph) (cfunction? ph))
    (errorf "dialect %q: :placeholder must be a function, got %q" name ph))
  (put dialect-registry name
       {:name name
        :placeholder ph
        :quote (get spec :quote quote-ansi)})
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
(register-dialect! :sqlite {:placeholder (fn [_] "?")})
(register-dialect! :postgres {:placeholder (fn [n] (string "$" n))})

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

# -- entry point ---------------------------------------------------------

(defn format
  ``Compile a statement map into [sql params] for a dialect (a name or
  a dialect value; default :ansi). The statement kind is the map's
  head key: :select/:insert/:update/:delete.``
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
      # a bare {:from ...} still reads as a select
      (get stmt :from) (compile-select ctx stmt)
      (errorf "sql: statement %q has no :select/:insert/:update/:delete" stmt)))
  [sql (tuple ;(ctx :params))])
