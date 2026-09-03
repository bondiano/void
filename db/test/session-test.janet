# Sessions in the database: the store void/db-http contributes, and the
# composition it makes possible — a fleet with sessions and no redis,
# which until now could not be expressed.
(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/deploy :as deploy)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/db :as db)
(import void/db/http :as db-http)

(log/set-level! "void.db" :error)

# -- the DDL is what it says ---------------------------------------------

(def ddl (db-http/session-ddl "sess"))
(assert (= 2 (length ddl)))
(assert (string/find "CREATE TABLE IF NOT EXISTS sess" (first ddl)))
(assert (string/find "sid text primary key" (first ddl)))
(assert (string/find "expires double precision not null" (first ddl)))
(assert (string/find "sess_expires_idx" (ddl 1))
        "the sweep has an index to walk")

# -- the driver ----------------------------------------------------------

(var rows @[])
(def [driver-value fake-state]
  (fake/make {:responder (fn [sql _]
                           (if (string/find "SELECT" sql)
                             @{:rows rows :count (length rows)}
                             @{:rows [] :count 0}))}))

(def driver-manifest
  (plugin/manifest 'test/driver
    :version "0.1.0"
    :requires {:void/db ">=0.0.1"}
    :components [(system/component :test/driver
                   :provides [:void/db-driver]
                   :start (fn [_ _] driver-value))]))

(def plugins ["void/http/init" "void/db/init" "void/db/http" driver-manifest])

(defn- config [extra]
  {:env @{}
   :cli (merge {:http {:port 0 :session {:enabled true :store :db}}
                :db {:pool {:size 1}}
                # the table is created by an :after-start hook; with a
                # fake driver there is nothing to create
                :db-http {:session {:auto-create false}}
                :log {:level :error}}
               extra)})

# -- the store, as the composition resolves it ---------------------------

(def boot (plugin/start! {:plugins plugins :profile :prod :config (config {})}))

(defer (plugin/shutdown! boot 3)
  (assert (= :fleet (deploy/shape)) ":prod is a fleet")
  (def entry (find |(= :void.http/session ($ :name)) (boot :stores)))
  (assert entry)
  (assert (= :db (entry :store)))
  (assert (true? (entry :shared?))
          "which is the whole point: a fleet with sessions and no redis")
  (assert (empty? (deploy/per-process (boot :stores)))
          "and the composition starts, where before it could not")

  # the SQL the store makes: an UPDATE that misses, then an INSERT
  (def store (get-in http/current-context [:session :store]))
  (fake/clear! fake-state)
  ((store :save) "abc" @{:user 7} 60)
  (def sqls (fake/sqls fake-state))
  (assert (string/find "UPDATE void_sessions" (first sqls)))
  (assert (string/find "INSERT INTO void_sessions" (sqls 1))
          "no dialect-specific upsert — an UPDATE that changed nothing, then an INSERT")

  # a load reads what the row holds, as a table the middleware can mutate
  (set rows @[@{:data "@{:user 7}" :expires (+ (os/clock :realtime) 60)}])
  (def loaded ((store :load) "abc"))
  (assert (table? loaded) "the middleware mutates the session in place")
  (assert (= 7 (loaded :user)))

  # an expired row is deleted on the way out rather than returned
  (set rows @[@{:data "@{:user 7}" :expires 1}])
  (fake/clear! fake-state)
  (assert (nil? ((store :load) "abc")))
  (assert (not (empty? (fake/matching fake-state "DELETE FROM void_sessions")))
          "expiry is swept, because a database has no TTL"))

(deploy/reset!)
(print "db session-test ok")
