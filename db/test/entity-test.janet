(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/core/schema :as schema)
(import void/db/driver :as driver)
(import void/db/pool :as pool)
(import void/db/state :as state)
(import void/db/entity :as entity)
(import void/db/erd :as erd)

(entity/defentity User
  {:id [:int {:db/pk true}]
   :email [:string {:format :email :db/unique true}]
   :brand-id [:optional [:int {:db/fk :Brand}]]
   :lock-version [:optional [:int {:db/version true}]]}
  :db/table "users"
  :db/rels {:brand [:belongs-to :Brand :brand-id]
            :bets [:has-many :Bet :user-id]})

(entity/defentity Brand
  {:id [:int {:db/pk true}]
   :name :string}
  :db/table "brands")

(entity/defentity Bet
  {:id [:int {:db/pk true}]
   :user-id [:int {:db/fk :User}]
   :amount :number}
  :db/table "bets")

# -- the declaration is a schema and a mapping ---------------------------

(assert (schema/node? User) "the binding is a normalized schema")
(assert (schema/valid? User {:id 1 :email "a@b.c"}) "and it validates")
(assert (not (schema/valid? User {:id 1 :email "nope"})) "format still applies")

(def CreateUser (schema/select User [:email :brand-id]))
(assert (schema/valid? CreateUser {:email "a@b.c" :brand-id 2})
        "a DTO projects straight off the entity")

(def desc (entity/resolve User))
(assert (= "users" (desc :table)) ":db/table")
(assert (= :id (desc :pk)) "primary key from :db/pk")
(assert (= "brand_id" (get-in desc [:fields :brand-id :column]))
        "kebab field -> snake column")
(assert (= :lock-version (desc :version)) ":db/version field is found")
(assert (= :belongs-to (get-in desc [:rels :brand :kind])) "relations parsed")

# the mapping is on the schema as well, for readers that only ever see
# schemas (admin widgets, migrations-diff)
(def ann (schema/db-annotations User))
(assert (= "users" (get-in ann [:schema :db/table])) ":db/table is a schema annotation too")
(assert (get-in ann [:fields :id :db/pk]) "and so are the field ones")
(assert (deep= (entity/resolve :User) desc) "entities resolve by name too")

# a schema that is not an entity says so
(assert (not (first (protect (entity/resolve (schema/normalize {:a :int})))))
        "a plain schema is not an entity")

# -- descriptor validation -----------------------------------------------

(assert (not (first (protect (entity/descriptor :Thing {:a :int}))))
        "an entity without :db/table is rejected")
(assert (not (first (protect (entity/descriptor :Thing {:a :int} :db/table "t"))))
        "an entity without a primary key is rejected")
(assert (not (first (protect (entity/descriptor
                               :Thing {:id [:int {:db/pk true}]} :db/table "t"
                               :db/rels {:x [:owns :Y :id]}))))
        "an unknown relation kind is rejected")

# -- test harness --------------------------------------------------------

(var responder nil)
(def [drv st] (fake/make {:responder (fn [sql params] (responder sql params))}))
(def p (pool/make (driver/normalize drv) {:size 2 :checkout-timeout 1}))
(setdyn state/pool-dyn p)

(defn- answer [spec] (set responder (fake/rows-responder spec)))

# -- mapping rows to instances -------------------------------------------

(answer {`FROM "users"` [{:id 1 :email "a@b.c" :brand_id 7 :lock_version 3}]})
(def u (entity/find User 1))
(assert (= 7 (u :brand-id)) "columns map back to field keys")
(assert (entity/instance? u) "a loaded row is an entity instance")
(assert (deep= @[:brand-id :email :id :lock-version] (sorted (keys u)))
        "the instance carries columns and nothing else — pp shows data")
(assert (= "users" ((entity/descriptor-of u) :table)) "the prototype knows the mapping")
(assert (string/find `WHERE "id" = ?` (get-in (fake/log st) [0 :sql]))
        "find selects by primary key")

# an unknown field in a write is a typo, not a silent drop
(assert (not (first (protect (entity/insert! User {:emial "a@b.c"}))))
        "unknown fields are rejected")

# -- dirty tracking: save! writes the diff, nothing else -----------------

(fake/clear! st)
(answer {"UPDATE" nil})
(assert (not (entity/dirty? u)) "a freshly loaded instance is clean")
(put u :email "new@b.c")
(assert (deep= @{:email "new@b.c"} (entity/changes u)) "changes are the diff")

(set responder (fn [sql _] (when (string/has-prefix? "UPDATE" sql) @{:rows [] :count 1})))
(entity/save! u)
(def upd (first (fake/matching st "UPDATE")))
(assert (= `UPDATE "users" SET "email" = ?, "lock_version" = ? WHERE ("id" = ? AND "lock_version" = ?)`
           (upd :sql))
        "a partial UPDATE of the changed column, guarded by the loaded version")
(assert (deep= ["new@b.c" 4 1 3] (upd :params)) "new value, bumped version, old version")
(assert (not (entity/dirty? u)) "the snapshot moved on after save!")
(assert (= 4 (u :lock-version)) "the version field is refreshed in place")

(fake/clear! st)
(entity/save! u)
(assert (empty? (fake/log st)) "saving an unchanged instance writes nothing")

# a lost optimistic-lock race is an error, not a silent overwrite
(set responder (fn [_ _] @{:rows [] :count 0}))
(put u :email "third@b.c")
(def [ok err] (protect (entity/save! u)))
(assert (not ok) "a stale save! fails")
(assert (string/find "modified concurrently" err) "and says why")

# -- preload: one batched IN per relation, never one query per row -------

(fake/clear! st)
(set responder
     (fn [sql _]
       (cond
         (string/find `FROM "users"` sql)
         @{:rows [{:id 1 :email "a@b.c" :brand_id 7}
                  {:id 2 :email "c@d.e" :brand_id 7}
                  {:id 3 :email "e@f.g" :brand_id 8}] :count 3}
         (string/find `FROM "brands"` sql)
         @{:rows [{:id 7 :name "seven"} {:id 8 :name "eight"}] :count 2}
         @{:rows [] :count 0})))

(def users (entity/query User {:where [:= :brand-id 7] :preload [:brand]}))
(assert (= 3 (length users)) "rows loaded")
(assert (= 2 (length (fake/log st))) "two queries in total, whatever the row count")
(def brands-q (first (fake/matching st `FROM "brands"`)))
(assert (string/find `"id" IN (?, ?)` (brands-q :sql)) "the parents come back in one IN")
(assert (deep= [7 8] (brands-q :params)) "with the distinct foreign keys")
(assert (= "seven" ((entity/rel (first users) :brand) :name)) "and are attached")
(assert (= "eight" ((entity/rel (in users 2) :brand) :name)) "each to the right row")

# has-many groups the other way round
(fake/clear! st)
(set responder
     (fn [sql _]
       (cond
         (string/find `FROM "users"` sql)
         @{:rows [{:id 1 :email "a@b.c"} {:id 2 :email "c@d.e"}] :count 2}
         (string/find `FROM "bets"` sql)
         @{:rows [{:id 10 :user_id 1 :amount 5} {:id 11 :user_id 1 :amount 6}]
           :count 2}
         @{:rows [] :count 0})))
(def with-bets (entity/query User {:preload [:bets]}))
(assert (= 2 (length (fake/log st))) "still one query per relation")
(assert (= 2 (length (entity/rel (first with-bets) :bets))) "children grouped by owner")
(assert (empty? (entity/rel (in with-bets 1) :bets))
        "an owner with no children gets an empty list")

# a belongs-to with no match preloads to nil — and stays preloaded
(fake/clear! st)
(set responder (fn [sql _]
                 (if (string/find `FROM "users"` sql)
                   @{:rows [{:id 1 :email "a@b.c" :brand_id 99}] :count 1}
                   @{:rows [] :count 0})))
(def orphan (first (entity/query User {:preload [:brand]})))
(fake/clear! st)
(assert (nil? (entity/rel orphan :brand)) "a missing parent is nil")
(assert (empty? (fake/log st)) "and is not re-queried per access")

# -- the N+1 guard -------------------------------------------------------

(fake/clear! st)
(set responder (fn [sql _]
                 (if (string/find `FROM "users"` sql)
                   @{:rows [{:id 1 :email "a@b.c" :brand_id 7}] :count 1}
                   @{:rows [{:id 7 :name "seven"}] :count 1})))
(def lone (first (entity/query User {})))

(with-dyns [entity/guard-dyn :strict]
  (def [ok err] (protect (entity/rel lone :brand)))
  (assert (not ok) "under :strict an unplanned rel is an error")
  (assert (string/find ":preload" err) "and the message names the fix"))

(with-dyns [entity/guard-dyn :off]
  (assert (= "seven" ((entity/rel lone :brand) :name))
          "with the guard off the relation still loads (one extra query)"))

(assert (not (first (protect (entity/rel lone :nope))))
        "an unknown relation is an error in any mode")

# a mistyped query option must not quietly change the query
(assert (not (first (protect (entity/query User {:preloads [:brand]}))))
        "an unknown query option is rejected")
(assert (not (first (protect (entity/count User {:limit 1}))))
        "count takes :where and nothing else")

# -- identity map (opt-in) -----------------------------------------------

(fake/clear! st)
(set responder (fn [_ _] @{:rows [{:id 1 :email "a@b.c"}] :count 1}))
(entity/with-identity-map
  (def a (entity/find User 1))
  (def b (entity/find User 1))
  (assert (= a b) "inside the scope one row is one instance")
  (assert (= 1 (length (fake/log st))) "and one query"))
(fake/clear! st)
(def x (entity/find User 1))
(def y (entity/find User 1))
(assert (not= x y) "outside the scope every find is a fresh instance")
(assert (= 2 (length (fake/log st))) "identity map is off by default")

# -- writes --------------------------------------------------------------

(fake/clear! st)
(set responder (fn [sql _]
                 (cond
                   (string/has-prefix? "INSERT" sql) @{:rows [] :count 1 :inserted-id 42}
                   (string/find `FROM "users"` sql)
                   @{:rows [{:id 42 :email "new@b.c"}] :count 1}
                   @{:rows [] :count 0})))
(def created (entity/insert! User {:email "new@b.c"}))
(assert (= 42 (created :id)) "without RETURNING the row is re-read by insert id")
(assert (deep= @[1 1] (map |($ :conn) (fake/log st)))
        "insert and re-read share one connection")

(fake/clear! st)
(entity/update! User 42 {:email "x@y.z"})
(assert (= `UPDATE "users" SET "email" = ? WHERE "id" = ?` (get-in (fake/log st) [0 :sql]))
        "update! patches by primary key")
(fake/clear! st)
(entity/delete! User 42)
(assert (= `DELETE FROM "users" WHERE "id" = ?` (get-in (fake/log st) [0 :sql]))
        "delete! by primary key")

# -- a :db/column that is not snake_case is used verbatim (M2) -----------

(entity/defentity Event
  {:id [:int {:db/pk true}]
   :created-at [:int {:db/column "createdAt"}]}
  :db/table "events")

(fake/clear! st)
(answer {`FROM "events"` [{:id 1 :createdAt 99}]})
(def ev (entity/find Event 1))
(def find-sql (get-in (fake/log st) [0 :sql]))
(assert (string/find `"createdAt"` find-sql)
        "the column is selected under its exact name, not snake_cased to created_at")
(assert (not (string/find "created_at" find-sql))
        "and never as the non-existent snake column")
(assert (= 99 (ev :created-at))
        "the exact column read back maps onto the field — no read/write mismatch")

(fake/clear! st)
(entity/update! Event 1 {:created-at 100})
(def upd-sql (get-in (fake/log st) [0 :sql]))
(assert (string/find `SET "createdAt" = ?` upd-sql)
        "and a write targets the exact column too")

# -- erd is a projection of the same declarations ------------------------

(def diagram (erd/mermaid [:User :Brand :Bet]))
(assert (string/find "erDiagram" diagram) "mermaid header")
(assert (string/find "id PK" diagram) "primary keys marked")
(assert (string/find "brand_id FK" diagram) "foreign keys marked")
(assert (string/find "User }o--|| Brand : brand" diagram) "belongs-to cardinality")
(assert (string/find "User ||--o{ Bet : bets" diagram) "has-many cardinality")

(print "entity-test: ok")
