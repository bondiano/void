### void/db-http — the two pieces of void/db that need void/http
### (CONTRACTS v1 row `:void.db/txn`).
###
### Kept a separate plugin so a CLI or worker process never drags the
### HTTP kernel in. It carries two things that have nothing to do with
### each other except that dependency: declarative route transactions,
### and the session store in the database.
###
### **Sessions in the database.** Until this existed, a fleet with
### sessions needed redis — `void/redis-http` was the only shared
### `:void.http/session-store` there was, so "we run two replicas" and
### "we do not want a second piece of infrastructure" could not both be
### true. An application that already has a database now has a session
### store:
###
###     (void/run! {:plugins [:void/http :void/db :void/db-http ...]})
###     # config/prod.janet
###     {:http {:session {:store :db}}}
###
### It is a table of three columns and no cleverness — the id, the
### session as jdn, and the absolute expiry. Two decisions worth
### stating:
###
### The clock is `os/clock :realtime`, not `:monotonic`. A monotonic
### clock counts from an arbitrary point *per process*, so an expiry
### written by one replica means nothing to the next one; the in-memory
### store can use it precisely because nobody else ever reads its
### numbers.
###
### Expiry is swept, not left to the engine. A database has no TTL, so
### the store deletes what is past its expiry — lazily on `load` (which
### is where correctness is at stake) and in bulk on `:sweep`, which
### the session middleware calls on a schedule of saves. A row that
### expired and was never asked for again costs one row until a sweep
### walks past it, which is the honest trade for not adding a second
### periodic task to the process.
###
### **Declarative route transactions.** A route (or a whole group)
### marked
###
###     {:void.db/txn true}
###     {:void.db/txn {:isolation :serializable}}
###
### runs its handler inside (db/with-tx ...) — one connection for the
### request, committed when the handler returns a response and rolled
### back when it throws. The wrapper sits at the business phase, so
### parsing, session, auth and validation have all happened before the
### transaction opens and nothing holds a connection while a body is
### being read.
###
### Errors keep their meaning: an `errors/abort` (or any panic) rolls
### the transaction back and then propagates to the error renderers
### untouched — the response is still rendered outside the
### transaction.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/middleware :as middleware)
(import ./builder :as builder)
(import ./state :as state)

(def log-ns "void.db.http")

# -- sessions in the database --------------------------------------------

(def Config
  "Schema of the [:db-http] config slice."
  {:session [:optional {:table [:optional :string]
                        :auto-create [:optional :boolean]}]})

(def defaults
  "Defaults of the [:db-http] slice."
  {:session {:table "void_sessions" :auto-create true}})

(defn- session-cfg []
  (merge (defaults :session)
         (or (get-in plugin/current-boot [:config :values :db-http :session]) {})))

(defn session-ddl
  ``The statements the session table needs, as a tuple of SQL strings
  — what `[:db-http :session :auto-create]` runs at boot and what
  `void db-http session-ddl` prints for a deployment that would rather
  run its own migration.``
  [&opt table]
  (default table (get-in defaults [:session :table]))
  [(string "CREATE TABLE IF NOT EXISTS " table " (\n"
           "  sid text primary key,\n"
           "  data text not null,\n"
           "  expires double precision not null\n)")
   (string "CREATE INDEX IF NOT EXISTS " table "_expires_idx ON " table
           " (expires)")])

(defn create-session-table!
  "Run `session-ddl` — idempotent, and safe to run at every boot."
  [&opt table]
  (each sql (session-ddl table)
    (state/execute-sql sql [] {:kind :write :prepared false}))
  nil)

(defn- ph [n]
  (((builder/dialect ((state/driver) :dialect)) :placeholder) n))

(defn session-store
  ``A `:void.http/session-store` over the running void/db pool. Which
  database and which dialect are read off the pool at call time, so
  the store is built once — at :before-start, before there is a pool —
  and outlives a restart of the one that appears later.``
  [&opt opts]
  (default opts {})
  (def tbl (get opts :table (get-in defaults [:session :table])))
  (defn now [] (os/clock :realtime))
  (defn sweep []
    (state/execute-sql (string "DELETE FROM " tbl " WHERE expires <= " (ph 1))
                       [(now)] {:kind :write})
    nil)
  {:name :db
   :table tbl
   :load (fn load [sid]
           (when-let [row (first (state/query
                                   [(string "SELECT data, expires FROM " tbl
                                            " WHERE sid = " (ph 1)) [sid]]))]
             (if (<= (get row :expires 0) (now))
               (do (state/execute-sql
                     (string "DELETE FROM " tbl " WHERE sid = " (ph 1))
                     [sid] {:kind :write})
                   nil)
               # the middleware mutates what it is given, so it has to
               # be a table: a struct read out of jdn would fail on the
               # first (put (req :session) ...)
               (let [data (parse (get row :data "@{}"))]
                 (if (table? data) data (table ;(kvs data)))))))
   :save (fn save [sid data ttl]
           (def expires (+ (now) ttl))
           (def encoded (string/format "%j" data))
           # UPDATE-then-INSERT rather than a dialect-specific upsert:
           # ON CONFLICT is spelled differently everywhere, and a
           # session id is 128 bits of randomness, so the INSERT that
           # races another INSERT of the same id is a thing that does
           # not happen
           (def n (get (state/execute-sql
                         (string "UPDATE " tbl " SET data = " (ph 1)
                                 ", expires = " (ph 2) " WHERE sid = " (ph 3))
                         [encoded expires sid] {:kind :write})
                       :count 0))
           (when (zero? n)
             (state/execute-sql
               (string "INSERT INTO " tbl " (sid, data, expires) VALUES ("
                       (ph 1) ", " (ph 2) ", " (ph 3) ")")
               [sid encoded expires] {:kind :write}))
           sid)
   :delete (fn delete [sid]
             (state/execute-sql (string "DELETE FROM " tbl " WHERE sid = " (ph 1))
                                [sid] {:kind :write})
             nil)
   :sweep sweep})

(plugin/contribute! :void.http/session-store
  {:name :db
   # the table name is read at build time; the ttl arrives with each
   # save, like every other store
   :make (fn make-store [_session-config] (session-store {:table ((session-cfg) :table)}))
   :shared? true})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 300
   :name :db-http/session-table
   :doc "Create the session table when [:db-http :session :auto-create] and this composition actually uses the :db session store"
   :fn (fn session-table [boot]
         (def cfg (session-cfg))
         (when (and (cfg :auto-create)
                    (= :db (get-in boot [:config :values :http :session :store])))
           (create-session-table! (cfg :table))
           (log/info "db session table ready" :ns log-ns :table (cfg :table))))})

(plugin/contribute! :void.core/cli
  {:name :db-http/session-ddl
   :read-only? true
   :doc "Print the SQL the database session store needs: void db-http session-ddl"
   :fn (fn cli-ddl [& args]
         (unless (empty? args)
           (errorf "void db-http session-ddl takes no arguments (got %q)" (string/join args " ")))
         (each sql (session-ddl ((session-cfg) :table))
           (printf "%s;\n" sql)))})

# -- declarative route transactions --------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.db/txn
   :schema [:or :boolean {:isolation [:optional :keyword]}]
   :doc "Run the handler inside a database transaction: true, or {:isolation :serializable} passed to the driver's BEGIN"
   :merge :replace})

(defn- tx-opts [rmeta]
  (def v (get rmeta :void.db/txn))
  (if (dictionary? v) v {}))

(plugin/contribute! :void.http/middleware
  {:name :void.db/txn
   :phase middleware/phase/business
   :doc "Wrap handlers of routes marked :void.db/txn in db/with-tx — a commit on the way out, a rollback on any error"
   :when (fn [rmeta] (truthy? (get rmeta :void.db/txn)))
   :wrap (fn [handler]
           # :when already decided this route wants a transaction; the
           # isolation is read once, at table-build time
           (fn db-txn [req]
             (state/with-tx* (tx-opts (get-in req [:void/route :meta] {}))
                             (fn txn-handler [] (handler req)))))})

(plugin/defplugin void/db-http
  :doc "The two pieces of void/db that need void/http: the :void.db/txn route metadata key, which runs a handler inside db/with-tx, and the :db session store — a shared session store for an application that has a database and would rather not also have a redis."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/db ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :db-http
  :config-schema Config
  :config-defaults defaults)
