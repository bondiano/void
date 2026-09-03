# The database session store against a real database. The fake driver in
# void/db pins the SQL this store makes; this pins that the SQL means what
# it was meant to mean, on an engine.
(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/db :as db)
(import void/db/http :as db-http)
(import void/db/state :as state)

(log/set-level! "void.db" :error)

(def plugins ["void/db/init" "void/db-sqlite/init"])
(def config
  {:env @{}
   :cli {:db {:pool {:size 1}}
         :db-sqlite {:path ":memory:"}
         :log {:level :error :levels {"void.db.query" :fatal}}}})

(def boot (plugin/start! {:plugins plugins :profile :test :config config}))

(defer (plugin/shutdown! boot 3)
  # one connection in the pool, so an in-memory database is one database
  (db/with-conn
    (db-http/create-session-table! "void_sessions")
    (def store (db-http/session-store))

    (assert (nil? ((store :load) "missing")))

    ((store :save) "s1" @{:user 7 :roles [:admin]} 60)
    (def loaded ((store :load) "s1"))
    (assert (table? loaded) "the middleware gets a table it can mutate")
    (assert (= 7 (loaded :user)))
    (assert (deep= [:admin] (loaded :roles))
            "jdn brings keywords back as keywords, which json would not")

    # saving again is an update, not a second row
    ((store :save) "s1" @{:user 8} 60)
    (assert (= 8 (get ((store :load) "s1") :user)))
    (assert (= 1 (db/value ["SELECT count(*) FROM void_sessions" []]))
            "one row per session id")

    ((store :delete) "s1")
    (assert (nil? ((store :load) "s1")))

    # expiry: lazily on load, in bulk on sweep
    ((store :save) "gone" @{:x 1} -1)
    (assert (nil? ((store :load) "gone")) "an expired session is not returned")
    (assert (zero? (db/value ["SELECT count(*) FROM void_sessions" []]))
            "and the row goes with it")

    ((store :save) "gone2" @{:x 1} -1)
    ((store :save) "alive" @{:x 2} 3600)
    ((store :sweep))
    (assert (= 1 (db/value ["SELECT count(*) FROM void_sessions" []]))
            "the sweep takes the expired rows and leaves the rest")
    (assert (= 2 (get ((store :load) "alive") :x)))

    # two ids do not collide
    ((store :save) "a" @{:who :a} 60)
    ((store :save) "b" @{:who :b} 60)
    (assert (= :a (get ((store :load) "a") :who)))
    (assert (= :b (get ((store :load) "b") :who)))))

(print "db-sqlite session-test ok")
