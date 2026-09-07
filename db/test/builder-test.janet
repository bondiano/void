(import ../test-support/paths)
(import void/db/builder :as sql)

# -- identifiers ---------------------------------------------------------

(assert (= "brand_id" (sql/snake :brand-id)) "kebab -> snake")
(assert (= "order_item" (sql/snake :OrderItem)) "camel -> snake")
(assert (= "applied_at" (sql/snake "applied_at")) "already snake stays")

# -- select --------------------------------------------------------------

(def [s p] (sql/format {:select [:id :email] :from "users"}))
(assert (= `SELECT "id", "email" FROM "users"` s) "columns quoted")
(assert (empty? p) "no params")

(def [s2 p2]
  (sql/format {:select [:*] :from "users"
               :where [:and [:= :brand-id 7] [:in :status ["a" "b"]]]
               :order-by [[:created-at :desc] :id]
               :limit 50 :offset 100}))
(assert (= (string `SELECT * FROM "users" WHERE ("brand_id" = ? AND "status" IN (?, ?)) `
                   `ORDER BY "created_at" DESC, "id" LIMIT ? OFFSET ?`)
           s2)
        "full select")
(assert (deep= [7 "a" "b" 50 100] p2) "params in order")

# a keyword on either side of a comparison is a column — that is what
# makes join conditions read naturally
(def [s3 _] (sql/format {:select [:*] :from "users"
                         :join [["brands" [:= :users.brand-id :brands.id]]]}))
(assert (= (string `SELECT * FROM "users" JOIN "brands" `
                   `ON "users"."brand_id" = "brands"."id"`)
           s3)
        "join on qualified columns")

# ... so data that happens to be a keyword needs [:val ...]
(def [_ p4] (sql/format {:select [:*] :from "users" :where [:= :role [:val :admin]]}))
(assert (deep= [:admin] p4) "[:val x] is a parameter, not a column")

# the dictionary shorthand is always column = value
(def [s5 p5] (sql/format {:select [:*] :from "users" :where {:email "a@b.c"}}))
(assert (= `SELECT * FROM "users" WHERE "email" = ?` s5) "map where")
(assert (deep= ["a@b.c"] p5) "map where params")

# nil (and the explicit null) compare with IS NULL, never = ?
(def [s6 p6] (sql/format {:select [:*] :from "users"
                          :where [:and [:= :deleted-at sql/null]
                                  [:<> :banned-at nil]]}))
(assert (= `SELECT * FROM "users" WHERE ("deleted_at" IS NULL AND "banned_at" IS NOT NULL)` s6)
        "null comparisons")
(assert (empty? p6) "IS NULL takes no parameter")

# an empty IN is a contradiction, not a syntax error
(def [s7 _] (sql/format {:select [:*] :from "users" :where [:in :id []]}))
(assert (string/has-suffix? "WHERE 1 = 0" s7) "empty IN never matches")
(def [s8 _] (sql/format {:select [:*] :from "users" :where [:not-in :id []]}))
(assert (string/has-suffix? "WHERE 1 = 1" s8) "empty NOT IN always matches")

(def [s9 p9] (sql/format {:select [[:raw "count(*) AS n"]] :from "users"
                          :where [:between :age 18 30]}))
(assert (= `SELECT count(*) AS n FROM "users" WHERE "age" BETWEEN ? AND ?` s9)
        "raw fragment and between")
(assert (deep= [18 30] p9) "between params")

# -- dialects ------------------------------------------------------------

(def [s10 _] (sql/format {:select [:*] :from "users" :where [:= :id 1]} :postgres))
(assert (= `SELECT * FROM "users" WHERE "id" = $1` s10) "postgres placeholders")

(assert (not (first (protect (sql/format {:select [:*] :from "users"} :oracle))))
        "unknown dialect is rejected")

# -- writes --------------------------------------------------------------

(def [s11 p11] (sql/format {:insert "users" :values {:email "a@b.c" :brand-id 7}
                            :returning true}))
(assert (= `INSERT INTO "users" ("brand_id", "email") VALUES (?, ?) RETURNING *` s11)
        "insert with returning")
(assert (deep= [7 "a@b.c"] p11) "insert params follow the column order")

(def [s12 p12] (sql/format {:insert "users"
                            :values [{:email "a"} {:email "b"}]}))
(assert (= `INSERT INTO "users" ("email") VALUES (?), (?)` s12) "multi-row insert")
(assert (deep= ["a" "b"] p12) "multi-row params")

(assert (not (first (protect (sql/format {:insert "users"
                                          :values [{:email "a"} {:name "b"}]}))))
        "ragged multi-row insert is rejected")

(def [s13 p13] (sql/format {:update "users" :set {:email "x" :seen-at sql/null}
                            :where [:= :id 3]}))
(assert (= `UPDATE "users" SET "email" = ?, "seen_at" = ? WHERE "id" = ?` s13)
        "update")
(assert (deep= ["x" nil 3] p13) "explicit null is a parameter in :set")

(def [s14 p14] (sql/format {:delete "users" :where {:id 9}}))
(assert (= `DELETE FROM "users" WHERE "id" = ?` s14) "delete")
(assert (deep= [9] p14) "delete params")

# -- DDL: the same statement, spelled by the dialect ---------------------

(def create-users
  {:create-table "users"
   :columns [[:id :serial {:primary-key true}]
             [:email :text {:null false :unique true}]
             [:brand-id :int {:refs [:brands :id] :on-delete :cascade}]
             [:signups :int {:null false :default 0}]
             [:seen-at :timestamptz]
             [:payload :jsonb]]})

(def [ddl-sqlite ddl-params] (sql/format create-users :sqlite))
(assert (empty? ddl-params) "DDL takes no parameters — a DEFAULT is part of the statement")
(assert (string/find `"id" integer PRIMARY KEY` ddl-sqlite)
        "sqlite numbers an integer primary key itself")
(assert (string/find `"seen_at" text` ddl-sqlite)
        "and has no timestamp type worth pretending about")
(assert (string/find `"payload" text` ddl-sqlite) "nor a json one")

(def [ddl-pg] (sql/format create-users :postgres))
(assert (string/find `"id" serial PRIMARY KEY` ddl-pg) "postgres has serial")
(assert (string/find `"seen_at" timestamp with time zone` ddl-pg) "and timestamptz")
(assert (string/find `"payload" jsonb` ddl-pg) "and jsonb")

(each ddl [ddl-sqlite ddl-pg]
  (assert (string/find `"email" text NOT NULL UNIQUE` ddl) "column options")
  (assert (string/find `"signups" integer NOT NULL DEFAULT 0` ddl) "literal default")
  (assert (string/find `REFERENCES "brands" ("id") ON DELETE CASCADE` ddl)
          "references, with the action spelled out"))

(assert (string/find "CREATE TABLE IF NOT EXISTS"
                     ((sql/format {:create-table "t" :if-not-exists true
                                   :columns [[:id :int]]}) 0))
        ":if-not-exists")

(assert (= `CREATE TABLE "t" (
  "a" integer,
  "b" integer,
  PRIMARY KEY ("a", "b")
)`
           ((sql/format {:create-table "t" :columns [[:a :int] [:b :int]]
                         :primary-key [:a :b]}) 0))
        "a composite primary key is a table-level clause")

(assert (= `DROP TABLE IF EXISTS "users"`
           ((sql/format {:drop-table "users" :if-exists true}) 0)))
(assert (= `ALTER TABLE "users" ADD COLUMN "slug" text NOT NULL`
           ((sql/format {:alter-table "users"
                         :add-column [:slug :text {:null false}]}) 0)))
(assert (= `ALTER TABLE "users" DROP COLUMN "slug"`
           ((sql/format {:alter-table "users" :drop-column :slug}) 0)))
(assert (= `ALTER TABLE "users" RENAME COLUMN "slug" TO "handle"`
           ((sql/format {:alter-table "users" :rename-column [:slug :handle]}) 0)))
(assert (= `CREATE UNIQUE INDEX IF NOT EXISTS "users_email_idx" ON "users" ("email")`
           ((sql/format {:create-index "users_email_idx" :on "users"
                         :columns [:email] :unique true :if-not-exists true}) 0)))
(assert (= `DROP INDEX IF EXISTS "users_email_idx"`
           ((sql/format {:drop-index "users_email_idx" :if-exists true}) 0)))

# what the builder has no spelling for is still reachable
(assert (string/find `"doc" tsvector`
                     ((sql/format {:create-table "t"
                                   :columns [[:doc [:raw "tsvector"]]]}) 0))
        "[:raw sql] is the escape hatch for a type only one engine has")

(assert (not (first (protect (sql/format {:create-table "t"
                                          :columns [[:a :timestampz]]}))))
        "a mistyped column type names the ones that exist")
(assert (not (first (protect (sql/format {:create-table "t"
                                          :columns [[:a :int {:nul false}]]}))))
        "a mistyped column option is an error, not a silent drop")
(assert (not (first (protect (sql/format {:create-table "t" :columns []}))))
        "a table with no columns is rejected")
(assert (not (first (protect (sql/format {:alter-table "t"
                                          :add-column [:a :int]
                                          :drop-column :b}))))
        "one change per :alter-table, because that is what the engines do")
(assert (not (first (protect (sql/format {:create-index "i" :columns [:a]}))))
        ":create-index needs :on")

# -- DDL string DEFAULT: MySQL escapes the backslash too (M1) ------------

# a value carrying `\'`: on a backslash-escaping dialect the `\` must be
# doubled, or `\'` reads as an escaped quote, the next `'` closes the
# string, and the tail becomes bare SQL
(def backslash-default
  {:create-table "t" :columns [[:a :text {:default `a\' , (select 1)`}]]})
(def [ddl-my] (sql/format backslash-default :mysql))
(assert (string/find "DEFAULT 'a\\\\'' , (select 1)'" ddl-my)
        "mysql doubles both the backslash and the quote in a DDL default")
(def [ddl-pg2] (sql/format backslash-default :postgres))
(assert (string/find "DEFAULT 'a\\'' , (select 1)'" ddl-pg2)
        "a non-backslash dialect doubles only the quote (a backslash is literal there)")
(assert (string/find `DEFAULT 'C:\\tmp'`
                     ((sql/format {:create-table "t"
                                   :columns [[:p :text {:default `C:\tmp`}]]} :mysql) 0))
        "and a harmless Windows path still compiles to valid MySQL DDL")

# -- [:col name]: an exact column identifier, never snake_cased (M2) ------

(def [col-s col-p]
  (sql/format {:select [[:col "createdAt"]] :from "t"
               :where [:= [:col "createdAt"] 5]} :postgres))
(assert (= `SELECT "createdAt" FROM "t" WHERE "createdAt" = $1` col-s)
        "[:col name] quotes the name verbatim on both sides, no snake")
(assert (deep= [5] col-p) "and the data operand stays a parameter")
(assert (= `SELECT "created_at" FROM "t"`
           ((sql/format {:select [:createdAt] :from "t"} :postgres) 0))
        "a keyword column still snakes — [:col ...] is the opt-out")

# -- rejected statements -------------------------------------------------

(assert (not (first (protect (sql/format {:select [:*]})))) "select needs :from")
(assert (not (first (protect (sql/format {:select [:*] :from "u" :ordr-by [:id]}))))
        "a mistyped key fails instead of being ignored")
(assert (not (first (protect (sql/format {:update "u" :set {}}))))
        "empty :set is rejected")
(assert (not (first (protect (sql/format {:select [:*] :from "u"
                                          :where [:= :a :b :c]}))))
        "malformed comparison is rejected")

# -- [:sql fragment params]: raw SQL that carries values -----------------

# the whole point: the same fragment on both placeholder styles, and
# numbered by its position in the statement rather than in itself
(def with-fragment
  {:update "rates" :set {:n [:sql "n + ?" [1]]} :where [:= :queue "q"]})
(assert (= [`UPDATE "rates" SET "n" = n + ? WHERE "queue" = ?` [1 "q"]]
           (sql/format with-fragment))
        "[:sql] parameters take their place among the statement's")
(assert (= [`UPDATE "rates" SET "n" = n + $1 WHERE "queue" = $2` [1 "q"]]
           (sql/format with-fragment :postgres))
        "and are renumbered for a $n dialect")

(assert (= [`SELECT * FROM "t" WHERE now() - "seen_at" > $1` [60]]
           (sql/format {:select [:*] :from "t"
                        :where [:sql "now() - \"seen_at\" > ?" [60]]} :postgres))
        "a fragment is a whole where clause too")

(assert (not (first (protect (sql/format {:select [[:sql "? + ?" [1]]] :from "t"}))))
        "a placeholder count that disagrees with the parameters is an error")
(assert (not (first (protect (sql/format {:select [[:sql 5 []]] :from "t"}))))
        "and the fragment must be a string")

# -- subqueries ----------------------------------------------------------

(assert (= [(string `SELECT * FROM "users" WHERE "id" IN `
                    `(SELECT "user_id" FROM "bans" WHERE "until" > ?)`)
            [5]]
           (sql/format {:select [:*] :from "users"
                        :where [:in :id {:select [:user-id] :from "bans"
                                         :where [:> :until 5]}]}))
        "IN over a statement is a subquery, not a list of values")

(assert (= (string `SELECT * FROM "orders" WHERE EXISTS `
                   `(SELECT 1 FROM "items" WHERE "items"."order_id" = "orders"."id")`)
           ((sql/format {:select [:*] :from "orders"
                         :where [:exists {:select [[:raw "1"]] :from "items"
                                          :where [:= :items.order-id :orders.id]}]}) 0))
        "EXISTS takes a statement")
(assert (not (first (protect (sql/format {:select [:*] :from "t"
                                          :where [:exists [:= :a 1]]}))))
        "and refuses a where clause where a statement belongs")

# a map in a *value* position is data — a json column, not a subquery
(assert (deep= [{:a 1}] ((sql/format {:update "t" :set {:meta {:a 1}}}) 1))
        "a map in :set is a parameter, because that is what a json column takes")

(assert (= (string `SELECT "u"."id" FROM "users" AS "u" `
                   `JOIN (SELECT "user_id" FROM "rates") AS "r" ON "r"."user_id" = "u"."id"`)
           ((sql/format {:select [:u.id] :from ["users" :u]
                         :join [[[{:select [:user-id] :from "rates"} :r]
                                 [:= :r.user-id :u.id]]]}) 0))
        "a table position takes an alias, and a derived table with one")
(assert (not (first (protect (sql/format {:select [:*]
                                          :from {:select [:id] :from "t"}}))))
        "a subquery in a FROM without an alias is refused, not guessed at")

# -- :lock ---------------------------------------------------------------

(def claim {:select [:id] :from "jobs" :where [:= :state "pending"] :limit 1
            :lock {:mode :update :skip-locked true}})
(assert (string/has-suffix? "FOR UPDATE SKIP LOCKED" ((sql/format claim :postgres) 0))
        "the claim postgres runs")
(assert (string/has-suffix? "FOR UPDATE" ((sql/format claim :mysql) 0))
        "mysql keeps the lock and loses SKIP LOCKED — one dialect for four engines")
(assert (string/has-suffix? "LIMIT ?" ((sql/format claim :sqlite) 0))
        "sqlite drops the clause: its writer is serialized already")
(assert (string/has-suffix? "LOCK IN SHARE MODE"
                            ((sql/format {:select [:*] :from "t" :lock :share} :mysql) 0))
        "the share lock is spelled MariaDB's way, which MySQL also takes")
(assert (not (first (protect (sql/format {:select [:*] :from "t" :lock :exclusive}))))
        "an unknown lock mode is an error")

# -- :on-conflict --------------------------------------------------------

(def upsert
  {:insert "rates" :values {:queue "q" :window-start 10 :n 1}
   :on-conflict {:on [:queue :window-start] :set {:n [:sql "n + ?" [1]]}}})
(assert (= [(string `INSERT INTO "rates" ("n", "queue", "window_start") VALUES ($1, $2, $3) `
                    `ON CONFLICT ("queue", "window_start") DO UPDATE SET "n" = n + $4`)
            [1 "q" 10 1]]
           (sql/format upsert :postgres))
        "the upsert, with the fragment numbered after the row")
(assert (= (string "INSERT INTO `rates` (`n`, `queue`, `window_start`) VALUES (?, ?, ?) "
                   "ON DUPLICATE KEY UPDATE `n` = n + ?")
           ((sql/format upsert :mysql) 0))
        "mysql spells the same declaration its way")

(assert (string/has-suffix? "ON CONFLICT DO NOTHING"
                            ((sql/format {:insert "log" :values {:id "a"}
                                          :on-conflict :nothing} :postgres) 0))
        ":nothing is the shorthand for the whole of a dropped row")
(assert (string/has-suffix? "ON DUPLICATE KEY UPDATE `id` = `id`"
                            ((sql/format {:insert "log" :values {:id "a"}
                                          :on-conflict :nothing} :mysql) 0))
        "which on mysql is a column set to itself")

(assert (string/find `"n" = excluded."n"`
                     ((sql/format {:insert "t" :values {:id 1 :n 2}
                                   :on-conflict {:on [:id] :set {:n [:excluded :n]}}}
                                  :postgres) 0))
        "[:excluded col] is the value the losing INSERT proposed")
(assert (string/find "`n` = VALUES(`n`)"
                     ((sql/format {:insert "t" :values {:id 1 :n 2}
                                   :on-conflict {:on [:id] :set {:n [:excluded :n]}}}
                                  :mysql) 0))
        "and mysql's spelling of the same thing")

(assert (string/find `WHERE "n" < $4`
                     ((sql/format {:insert "t" :values {:id 1 :n 2}
                                   :on-conflict {:on [:id] :set {:n 5} :where [:< :n 10]}}
                                  :postgres) 0))
        "a conditional upsert")
(assert (not (first (protect (sql/format {:insert "t" :values {:id 1 :n 2}
                                          :on-conflict {:on [:id] :set {:n 5}
                                                        :where [:< :n 10]}}
                                         :mysql))))
        "mysql has no condition for it, and a dropped condition would update rows it should not")
(assert (not (first (protect (sql/format {:insert "t" :values {:id 1}
                                          :on-conflict {:set {:n 5}}} :postgres))))
        "a DO UPDATE needs the conflict target postgres arbitrates by")

# -- partial indexes -----------------------------------------------------

(def unique-idx
  {:create-index "jobs_unique_idx" :on "jobs" :unique true :if-not-exists true
   :columns [:unique-key] :where [:<> :unique-key nil]})
(assert (= (string `CREATE UNIQUE INDEX IF NOT EXISTS "jobs_unique_idx" `
                   `ON "jobs" ("unique_key") WHERE "unique_key" IS NOT NULL`)
           ((sql/format unique-idx :postgres) 0))
        "a partial index is a statement, not a hand-written string")
(assert (not (first (protect (sql/format unique-idx :mysql))))
        "mysql has no partial index, and the caller decides what the index there is")

# a DDL predicate renders its values as literals: an engine takes no
# parameters in a CREATE INDEX
(assert (= [(string `CREATE INDEX "t_live_idx" ON "t" ("id") `
                    `WHERE ("state" = 'live' AND "n" > 3)`)
            []]
           (sql/format {:create-index "t_live_idx" :on "t" :columns [:id]
                        :where [:and [:= :state "live"] [:> :n 3]]}))
        "and takes no parameters")

(assert (= "CREATE INDEX `t_idx` ON `t` (`id`)"
           ((sql/format {:create-index "t_idx" :on "t" :columns [:id]
                         :if-not-exists true} :mysql) 0))
        "IF NOT EXISTS is dropped where the engine has not got it — the bare statement is the same statement")

# -- composing clauses ---------------------------------------------------

(assert (= [:and [:= :a 1] [:= :b 2]] (sql/all-of nil [:= :a 1] nil [:= :b 2]))
        "all-of skips the conditions that were not there")
(assert (= [:= :a 1] (sql/all-of [:= :a 1] nil)) "one clause is itself")
(assert (nil? (sql/all-of nil nil)) "and none is no condition at all")
(assert (= [:or [:= :a 1] [:= :b 2]] (sql/any-of [:= :a 1] [:= :b 2])) "any-of ORs")

(assert (= [:and [:= :a 1] [:= :b 2]]
           (get (sql/and-where {:select [:*] :from "t" :where [:= :a 1]} [:= :b 2]) :where))
        "and-where grows a partial statement")
(assert (= [:= :b 2]
           (get (sql/and-where {:select [:*] :from "t"} [:= :b 2]) :where))
        "onto a statement that had no condition")
(assert (deep= {:select [:*] :from "t"} (sql/and-where {:select [:*] :from "t"} nil))
        "and a nil clause leaves it alone")

(print "builder-test: ok")
