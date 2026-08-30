### void/auth-db — the three stores, over void/db (ADR-0023 §2).
###
### The half of void/auth that needs a database, kept a separate plugin
### so an application with its own user table — or with five operators
### in the config — never composes one. The split `void/cache` and
### `void/cache-redis` make.
###
### **The users table is the application's.** This plugin reads it; it
### does not own it, does not migrate it and does not decide what a
### user has. `[:auth-db :users]` names the table and the three or four
### columns that matter, and everything else in that table is the
### application's business:
###
###     {:auth-db {:users {:table "users"
###                        :id-column "id"
###                        :email-column "email"
###                        :password-column "password_hash"
###                        :claims-columns ["role" "brand_id"]}}}
###
### The subject is `"<kind>:<id>"` — `[:auth-db :users :subject-kind]`
### is the `user` in it — so that an identity carries a stable string
### and `void/authz` can tell a person from a service token by looking
### at it.
###
### **The two tables that *are* void's** — API tokens and one-time codes
### — come as DDL data rather than as a migration file, because a
### migration timeline belongs to the application (ADR-0009's argument
### about migrations being self-contained). One file in `db/migrations`:
###
###     (import void/auth/db :as auth-db)
###     (defn up [] (auth-db/tables))
###     (defn down [] (auth-db/drop-tables))
###
### and `void/db/builder` compiles it for whichever engine is running,
### so the same file works on sqlite and Postgres.
###
### **`:take` is a transaction.** A one-time code that two requests can
### redeem is not one-time, so the challenge store reads and deletes
### inside `db/with-tx` and treats "deleted zero rows" as "somebody
### else got it first".

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/db :as db)
(import ./store :as store)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.auth.db")

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:auth-db] config slice."
  {:users [:optional :dictionary]
   :tokens [:optional :dictionary]
   :challenges [:optional :dictionary]})

(def defaults
  ``Defaults of the [:auth-db] slice.

  The users half describes a table this plugin did not create — the
  names below are the common ones, and an application whose column is
  `hashed_password` says so rather than renaming its column.

  `:claims-columns` is empty on purpose: every column it names is read
  on every request that resolves an identity from the session, so the
  list should be the two or three an authorization policy actually
  uses, not the row.``
  {:users {:table "users"
           :id-column "id"
           :subject-kind "user"
           :email-column "email"
           :username-column nil
           :password-column "password_hash"
           :claims-columns []}
   :tokens {:table "auth_tokens"}
   :challenges {:table "auth_challenges"}})

(defn- slice [cfg]
  (def c (merge defaults (or cfg {})))
  (each key [:users :tokens :challenges]
    (put c key (merge (defaults key) (get cfg key {}))))
  c)

# -- DDL as data ---------------------------------------------------------

(defn tables
  ``The two tables void owns, as `void/db/builder` statements — put
  them in a migration of the application's own:

      (import void/auth/db :as auth-db)
      (defn up [] (auth-db/tables))

  `cfg` is the [:auth-db] slice, when the table names were changed.``
  [&opt cfg]
  (def c (slice cfg))
  (def tokens (get-in c [:tokens :table]))
  (def challenges (get-in c [:challenges :table]))
  [{:create-table tokens
    :columns [[:id :text {:primary-key true}]
              # the digest of the secret, never the secret (ADR-0023 §5)
              [:digest :text {:null false}]
              [:subject :text {:null false}]
              [:name :text]
              # JSON, because a scope list is a list and both engines
              # store it as text either way
              [:scopes :text]
              [:claims :text]
              [:created :int {:null false}]
              [:expires :int]
              [:used :int]]}
   {:create-index (string tokens "_subject_idx") :on tokens :columns [:subject]}

   {:create-table challenges
    :columns [[:handle :text {:primary-key true}]
              [:digest :text {:null false}]
              [:subject :text {:null false}]
              [:kind :text {:null false}]
              [:claims :text]
              [:created :int {:null false}]
              [:expires :int {:null false}]]}
   {:create-index (string challenges "_expires_idx") :on challenges :columns [:expires]}])

(defn drop-tables
  "The other direction, for a migration's `down`."
  [&opt cfg]
  (def c (slice cfg))
  [{:drop-table (get-in c [:challenges :table])}
   {:drop-table (get-in c [:tokens :table])}])

# -- helpers -------------------------------------------------------------

(defn- json-out [value]
  (if (or (nil? value) (and (indexed? value) (empty? value)) (and (dictionary? value) (empty? value)))
    nil
    (json/encode value)))

(defn- json-in [text]
  (when (and text (not (empty? (string text))))
    (def [ok value] (protect (json/decode text true)))
    (when ok value)))

(defn- column [cfg key]
  (keyword (get cfg key)))

# -- the user store ------------------------------------------------------

(defn user-store
  ``A user store over an existing table. Reads only: this plugin never
  writes to a table it did not create, so `:update-secret` is absent
  and a rehash-on-login is the application's to perform.``
  [cfg]
  (def table (keyword (cfg :table)))
  (def id-col (column cfg :id-column))
  (def kind (cfg :subject-kind))
  (def claims-cols (map keyword (get cfg :claims-columns [])))
  (defn subject-of [row] (string kind ":" (get row id-col)))
  (defn column-for [by]
    (case by
      :subject id-col
      :id id-col
      :email (column cfg :email-column)
      :username (when (cfg :username-column) (column cfg :username-column))
      (keyword by)))
  {:name :db
   :table table
   :find (fn db-find [selector]
           (def by (get selector :by :subject))
           (def raw (string (get selector :value)))
           # "user:42" addresses the id column by its id half; every
           # other selector is the value as given
           (def value
             (if (or (= by :subject) (= by :id))
               (let [prefix (string kind ":")]
                 (if (string/has-prefix? prefix raw)
                   (string/slice raw (length prefix))
                   raw))
               raw))
           (when-let [col (column-for by)]
             (db/one-row {:select [:*] :from table :where {col value} :limit 1})))
   :secret (fn db-secret [row] (get row (column cfg :password-column)))
   :subject subject-of
   # frozen: claims travel into an identity that outlives this call and
   # is read from several fibers, and a mutable table there is a shared
   # mutable that nobody expected
   :claims (fn db-claims [row]
             (freeze
               (tabseq [c :in claims-cols :when (not (nil? (get row c)))]
                 c (get row c))))})

# -- the token store -----------------------------------------------------

(defn token-store
  "An API-token store over the table `tables` creates."
  [cfg]
  (def table (keyword (cfg :table)))
  (defn row->record [row]
    (when row
      {:id (row :id)
       :digest (row :digest)
       :subject (row :subject)
       :name (row :name)
       # keywords on the way back, because that is what the memory
       # store holds and a scope check must not depend on which store
       # is behind the interface
       :scopes (map keyword (or (json-in (row :scopes)) []))
       :claims (or (json-in (row :claims)) {})
       :created (row :created)
       :expires (row :expires)
       :used (row :used)}))
  {:name :db
   :table table
   # rows in the application's database: every replica reads the same
   # tokens, which is the whole reason this plugin exists (ADR-0030)
   :shared? true
   :find (fn db-token-find [id]
           (row->record (db/one-row {:select [:*] :from table :where {:id id} :limit 1})))
   :put (fn db-token-put [record]
          (db/execute! {:insert table
                        :values [{:id (record :id)
                                  :digest (record :digest)
                                  :subject (record :subject)
                                  :name (get record :name)
                                  :scopes (json-out (get record :scopes))
                                  :claims (json-out (get record :claims))
                                  :created (get record :created)
                                  :expires (get record :expires)
                                  :used (get record :used)}]})
          record)
   :delete (fn db-token-delete [id]
             (pos? (db/execute! {:delete table :where {:id id}})))
   :touch (fn db-token-touch [id at]
            (db/execute! {:update table :set {:used at} :where {:id id}})
            nil)
   :list (fn db-token-list [subject]
           (map row->record
                (db/query-sql {:select [:*] :from table
                               :where {:subject subject}
                               :order-by [[:created :desc]]})))})

# -- the challenge store -------------------------------------------------

(defn challenge-store
  "A store for magic links and one-time codes, single-use by
  transaction."
  [cfg]
  (def table (keyword (cfg :table)))
  {:name :db
   :table table
   # a magic link issued by one replica is redeemable at any of them
   :shared? true
   :put (fn db-challenge-put [handle record ttl]
          (def now (os/time))
          (db/with-tx
            # issuing again for the same handle replaces what was sent
            # before, which is what makes "resend the code" mean
            # something
            (db/execute! {:delete table :where {:handle handle}})
            (db/execute! {:insert table
                          :values [{:handle handle
                                    :digest (record :digest)
                                    :subject (record :subject)
                                    :kind (string (get record :kind :link))
                                    :claims (json-out (get record :claims))
                                    :created (get record :created now)
                                    :expires (+ now ttl)}]}))
          handle)
   :take (fn db-challenge-take [handle]
           (def now (os/time))
           (db/with-tx
             (def row (db/one-row {:select [:*] :from table
                                   :where {:handle handle} :limit 1}))
             (when row
               # the delete is what makes it single-use, and doing it in
               # the same transaction as the read is what makes that
               # true with two requests in flight: whoever loses deletes
               # zero rows and gets nothing
               (def deleted (db/execute! {:delete table :where {:handle handle}}))
               (when (and (pos? deleted) (> (row :expires) now))
                 {:digest (row :digest)
                  :subject (row :subject)
                  :kind (keyword (row :kind))
                  :claims (or (json-in (row :claims)) {})
                  :created (row :created)}))))
   :sweep (fn db-challenge-sweep []
            (db/execute! {:delete table :where [:< :expires (os/time)]})
            nil)})

# -- components ----------------------------------------------------------

(def users-component
  (system/component :auth.db/users
    :doc "The user store over the application's own users table: read
    only, addressed by [:auth-db :users], and the source of the claims
    a session re-reads on every request."
    :deps [:db/pool]
    :provides [:void/auth-user-store]
    :config {:key :auth-db :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (log/info "auth db user store ready" :ns log-ns
                :table (get-in cfg [:users :table])
                :claims (get-in cfg [:users :claims-columns]))
      (store/normalize-user-store (user-store (cfg :users))))))

(def tokens-component
  (system/component :auth.db/tokens
    :doc "API tokens in the database — digests, never tokens. The table
    is void's own; put `(auth-db/tables)` in a migration."
    :deps [:db/pool]
    :provides [:void/auth-token-store]
    :config {:key :auth-db :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (store/normalize-token-store (token-store (cfg :tokens))))))

(def challenges-component
  (system/component :auth.db/challenges
    :doc "Magic links and one-time codes in the database, so a code
    issued by one worker can be redeemed at another — which an
    in-process store cannot do under prefork (ADR-0010) or a fleet."
    :deps [:db/pool]
    :provides [:void/auth-challenge-store]
    :config {:key :auth-db :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (store/normalize-challenge-store (challenge-store (cfg :challenges))))))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :auth/sweep
   :read-only? false
   :doc "Delete expired one-time codes: void auth sweep"
   :needs [:auth.db/challenges]
   :fn (fn cli-sweep [challenges & args]
         (unless (empty? args)
           (errorf "void auth sweep takes no arguments (got %q)" (string/join args " ")))
         ((challenges :sweep))
         (print "expired challenges deleted"))})

(plugin/defplugin void/auth-db
  :doc "The void/auth stores over void/db: the application's own users table read through :void.auth/user-store, plus API tokens and single-use one-time codes in two tables void owns (their DDL is data — put (auth-db/tables) in a migration)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/auth ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :auth-db
  :config-schema Config
  :config-defaults defaults
  :components [users-component tokens-component challenges-component])
