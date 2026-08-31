(import ../test-support/paths)
(import ../test-support/server)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/db :as db)

(log/set-level! "void.db" :error)

# The entity layer over an engine with no RETURNING.
#
# void/db-sqlite (on a new enough sqlite) and void/db-postgres both get
# the stored row back from the INSERT itself. MySQL cannot: there is no
# RETURNING clause, so the driver reports :returning false and the
# entity layer takes its other path — write, ask the driver for the
# insert id, read the row back. That path exists for this driver, and
# this file is where it is exercised against a real server: defaults
# the server filled in, the primary key it generated, and the
# relations, updates and deletes that hang off having the right id.

(if-not (server/available?)
  (do (server/skip "db-mysql entity")
      (os/exit 0)))

(def plugins ["void/db/init" "void/db-mysql/init"])
(def config
  {:env @{}
   :cli {:db {:pool {:size 2} :n1-guard :strict}
         :db-mysql (server/config)
         :log {:level :error :levels {"void.db.query" :fatal}}}})

(def authors (server/table-name "authors"))
(def posts (server/table-name "posts"))

(def boot (plugin/start! {:plugins plugins :profile :test :config config}))

(defer (plugin/shutdown! boot 5)
  (defer (do (db/execute-sql (string "DROP TABLE IF EXISTS `" posts "`") [] {:kind :write})
             (db/execute-sql (string "DROP TABLE IF EXISTS `" authors "`") [] {:kind :write}))

    (db/execute! {:create-table (keyword authors)
                  :columns [[:id :serial {:primary-key true}]
                            [:name :string {:unique true}]
                            [:active :bool {:default true}]]})
    (db/execute! {:create-table (keyword posts)
                  :columns [[:id :serial {:primary-key true}]
                            [:author-id :int {:null false :refs [(keyword authors) :id]}]
                            [:title :string]
                            [:views :int {:default 0}]
                            [:body :text]]})

    # declared at run time rather than with `defentity`, because the
    # table names carry a timestamp: same function, same registration
    (db/define-entity! :Author
                       {:id [:int {:db/pk true}]
                        :name [:string {:db/unique true}]
                        :active [:optional :boolean]}
                       [:db/table authors])
    (db/define-entity! :Post
                       {:id [:int {:db/pk true}]
                        :author-id [:int {:db/fk :Author}]
                        :title :string
                        :views [:optional :int]
                        :body [:optional :string]}
                       [:db/table posts
                        :db/rels {:author [:belongs-to :Author :author-id]}])

    # -- insert without RETURNING ----------------------------------------

    (def a (db/insert! :Author {:name "Ada"}))
    (assert (pos? (a :id))
            (string "the entity came back with the key MySQL generated — there "
                    "is no RETURNING here, so this is the driver's :insert-id "
                    "and a re-read"))
    (assert (= "Ada" (a :name)))
    (assert (= true (a :active))
            (string "and with the column default the SERVER filled in, which is "
                    "the part a client-side id could not have known"))

    (def found (db/find! :Author (a :id)))
    (assert (= "Ada" (found :name)) "and the row really is in the table")

    # a second insert gets a different key, which is the failure mode a
    # cached or reused insert id would have
    (def b (db/insert! :Author {:name "Grace"}))
    (assert (not= (a :id) (b :id)) "two inserts, two keys")

    # -- insert inside a transaction -------------------------------------
    #
    # mysql_insert_id is per connection, and `with-tx` holds one for the
    # whole block — so this is also the assertion that the entity layer
    # reads the id off the write it just did rather than asking the pool
    # again later.

    (db/with-tx
      (def c (db/insert! :Author {:name "Katherine"}))
      (def d (db/insert! :Author {:name "Dorothy"}))
      (assert (not= (c :id) (d :id)))
      (assert (= "Katherine" (get (db/find! :Author (c :id)) :name))
              "each row is findable by its own id, inside the transaction"))

    (assert (= 4 (db/count :Author)) "and all four survived the commit")

    # a rolled-back insert leaves nothing, ids included
    (db/with-tx
      (db/insert! :Author {:name "temporary"})
      (db/rollback!))
    (assert (= 4 (db/count :Author)) "a rolled-back insert is not a row")

    # -- update, save, delete --------------------------------------------

    (def p (db/insert! :Post {:author-id (a :id) :title "First" :body "hello"}))
    (assert (= 0 (p :views)) "an int default arrives as a number")

    (db/update! :Post (p :id) {:title "Renamed"})
    (assert (= "Renamed" (get (db/find! :Post (p :id)) :title)))

    (def loaded (db/find! :Post (p :id)))
    (put loaded :views 5)
    (db/save! loaded)
    (assert (= 5 (get (db/find! :Post (p :id)) :views))
            "save! writes only what changed, and it changed")

    # -- relations -------------------------------------------------------

    # the N+1 guard is :strict here, so a relation is navigated only
    # where it was asked for — which is the right shape to assert in
    (def post (db/one :Post {:where [:= :id (p :id)] :preload [:author]}))
    (assert (= "Ada" (get (db/rel post :author) :name))
            "a belongs-to navigates on the keys MySQL generated")

    (db/insert! :Post {:author-id (b :id) :title "Second" :body "hi"})
    (def all (db/query :Post {:order-by [[:id :asc]]}))
    (assert (= 2 (length all)))
    (db/preload! :Post all [:author])
    (assert (= "Ada" (get (db/rel (first all) :author) :name))
            "and a preload batches them without tripping the N+1 guard")

    (assert (= 1 (db/delete! :Post (p :id))))
    (assert (nil? (db/find :Post (p :id))))

    # -- a unique violation is still an error ----------------------------

    (def [ok err] (protect (db/insert! :Author {:name "Ada"})))
    (assert (not ok) "a duplicate key does not silently become a row")
    (assert (= 4 (db/count :Author)) "and nothing was written")))

(print "db-mysql entity-test ok")
