### blog/entities — the domain, declared once.
###
### `defentity` is a schema plus a db-mapping (ADR-0009): the binding
### *is* the normalized schema, so `schema/select` projects a form DTO
### straight off it, while the table, the primary key, the columns and
### the relations live in a descriptor the repository, `:preload` and
### `void db erd` all read. Nothing here names sqlite or Postgres — the
### driver is a config line (see main.janet).
(import void/core/schema :as schema)
(import void/db :as db)

# The :db/* props are annotations: parsed and stored, never consulted
# by validation (ADR-0008). They are what the repository, `:preload`
# and `void db erd` read — :db/type is the column type the migrations
# actually created, so the diagram says `text` and not `value`.

(db/defentity Author
  {:id [:int {:db/pk true :db/type "integer"}]
   :name [:string {:min 1 :max 60 :db/type "text"}]
   :email [:string {:format :email :db/unique true :db/type "text"}]}
  :db/table "authors"
  :db/rels {:articles [:has-many :Article :author-id]})

(db/defentity Article
  {:id [:int {:db/pk true :db/type "integer"}]
   :author-id [:int {:db/fk :Author :db/type "integer"}]
   :title [:string {:min 1 :max 120 :db/type "text"}]
   :body [:string {:min 1 :max 4000 :db/type "text"}]
   # denormalized, and kept honest by a background job rather than by
   # a callback — entities deliberately have none (ADR-0009)
   :comment-count [:optional [:int {:db/type "integer"}]]
   :created-at [:optional [:string {:db/type "text"}]]}
  :db/table "articles"
  :db/rels {:author [:belongs-to :Author :author-id]
            :comments [:has-many :Comment :article-id]})

(db/defentity Comment
  {:id [:int {:db/pk true :db/type "integer"}]
   :article-id [:int {:db/fk :Article :db/type "integer"}]
   :author-name [:string {:min 1 :max 60 :db/type "text"}]
   :body [:string {:min 1 :max 800 :db/type "text"}]
   :created-at [:optional [:string {:db/type "text"}]]}
  :db/table "comments"
  :db/rels {:article [:belongs-to :Article :article-id]})

# -- form DTOs: projections of the entities above, not copies ------------

(def NewArticle
  ``What the new-article form submits — one form over two entities:
  `merge` composes them, the outer `select` puts the fields in the
  order the page asks for (ADR-0008). The handler splits the value
  back into an author and an article inside one transaction.``
  (schema/select
    (schema/merge (schema/select Article [:title :body])
                  (schema/select Author [:name :email]))
    [:title :body :name :email]))

(def EditArticle
  "What the edit form submits — the two columns `save!` may change."
  (schema/select Article [:title :body]))

(def NewComment
  "What the comment form submits."
  (schema/select Comment [:author-name :body]))

(defn now
  ``An ISO-8601 UTC timestamp. Text on both engines, which is what
  keeps the migrations one file instead of two.``
  []
  (def d (os/date (os/time) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))
