# Migrations are SQL as data, DDL included: `void/db/builder` compiles
# this for whichever engine is running, so `[:id :serial {:primary-key
# true}]` is `"id" integer PRIMARY KEY` on sqlite and `"id" serial
# PRIMARY KEY` on Postgres and the file says neither.
#
# They are also deliberately self-contained — they run against the
# database as it was, not against today's entities. A migration that
# projected `defentity` would rewrite its own history every time a field
# changed (generation from the entity registry is a v2 story).

(defn up
  {:params [] :ret [{:keyword :any}]}
  "Create the authors and articles tables, plus the index the blog's
  feed queries lean on."
  []
  [{:create-table "authors"
    :columns [[:id :serial {:primary-key true}]
              [:name :text {:null false}]
              [:email :text {:null false :unique true}]]}

   {:create-table "articles"
    :columns [[:id :serial {:primary-key true}]
              [:author-id :int {:null false :refs [:authors :id]
                                :on-delete :cascade}]
              [:title :text {:null false}]
              [:body :text {:null false}]
              # denormalized; ./jobs.janet is what keeps it true
              [:comment-count :int {:null false :default 0}]
              # text, not :timestamptz, on purpose: the application
              # writes ISO-8601 strings so that a row reads the same on
              # both engines (see entities/now)
              [:created-at :text {:null false}]]}

   {:create-index "articles_created_at_idx"
    :on "articles" :columns [:created-at]}])

(defn down
  {:params [] :ret [{:keyword :any}]}
  "Drop articles before authors, undoing `up` in reverse of the
  foreign key it created."
  []
  [{:drop-table "articles"}
   {:drop-table "authors"}])
