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

# -- rejected statements -------------------------------------------------

(assert (not (first (protect (sql/format {:select [:*]})))) "select needs :from")
(assert (not (first (protect (sql/format {:select [:*] :from "u" :ordr-by [:id]}))))
        "a mistyped key fails instead of being ignored")
(assert (not (first (protect (sql/format {:update "u" :set {}}))))
        "empty :set is rejected")
(assert (not (first (protect (sql/format {:select [:*] :from "u"
                                          :where [:= :a :b :c]}))))
        "malformed comparison is rejected")

(print "builder-test: ok")
