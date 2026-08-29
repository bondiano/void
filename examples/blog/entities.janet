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
   :email [:string {:format :email :db/unique true :db/type "text"}]
   # a PHC string (`$scrypt$ln=14,r=8,p=1$…`), written by
   # `auth/hash-password` and read by void/auth-db's user store — which
   # reads the table directly, so this field exists for the *writes*:
   # registration and a password change. Optional, because the wave-2
   # rows have none and an author without a password just cannot sign in.
   :password-hash [:optional [:string {:db/type "text"}]]}
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

# One line of the audit trail (wave 3.6). Written only by ./audit, and
# only from a message: :message-id is unique, so a redelivery is
# recognised by the *database* rather than by a consumer trusting
# itself to be idempotent — which is the shape an at-least-once bus
# asks a writer to have.
(db/defentity AuditEvent
  {:id [:int {:db/pk true :db/type "integer"}]
   :message-id [:string {:db/unique true :db/type "text"}]
   :topic [:string {:db/type "text"}]
   :correlation-id [:string {:db/type "text"}]
   :actor [:optional [:string {:db/type "text"}]]
   :detail [:string {:db/type "text"}]
   :at [:string {:db/type "text"}]}
  :db/table "audit_events")

# -- form DTOs: projections of the entities above, not copies ------------

(def NewArticle
  ``What the new-article form submits. In wave 2 this form carried the
  author too — one form over two entities — and creating an article
  invented an author on the spot. Wave 3 took that away: the author is
  now whoever is signed in (`:void.auth/access :required` on the
  route), so the form is the article and nothing else, and the
  identity is not a field anybody can type.``
  (schema/select Article [:title :body]))

(def Registration
  ``What the sign-up form submits: an author, plus a password that is
  not a column. `schema/merge` composes the projection of the entity
  with the one field that has no place in it — the hash is what the
  table stores, and the plaintext exists for exactly the length of one
  request (ADR-0023 §4).``
  (schema/merge (schema/select Author [:name :email])
                {:password [:string {:min 8 :max 200}]}))

(def Credentials
  "What the sign-in form submits."
  {:email [:string {:format :email}]
   :password [:string {:min 1 :max 200}]})

(def MagicLink
  ``What the "mail me a link" form submits — an address and nothing
  else. There is no password here on purpose: this is the form for
  the visitor who does not have one to hand.``
  {:email [:string {:format :email}]})

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
