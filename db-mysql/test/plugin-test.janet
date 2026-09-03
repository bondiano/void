(import ../test-support/paths)
(import ../test-support/server)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/db :as db)
(import void/db/builder :as builder)
(import void/db-mysql/init :as mysql)

(log/set-level! "void.db" :error)

# The declarations, and what composes with them. Phases 1-5 of the
# kernel need no client library and no server — a plugin that is merely
# loaded must not require MySQL to exist (`void routes` on a laptop,
# the dry-run gate in CI) — so everything down to `plugin/dry-run` runs
# everywhere, and only `plugin/start!` at the bottom waits for a server.

(def plugins ["void/db/init" "void/db-mysql/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:db {:pool {:size 2} :n1-guard :strict}
                :log {:level :error :levels {"void.db.query" :fatal}}}
               extra)})

# -- the dialect ---------------------------------------------------------
#
# Registered by void/db/builder, which the driver names rather than
# defines: a driver declares which dialect it speaks and the builder
# owns the spelling.

(def d (builder/dialect :mysql))
(assert d "the :mysql dialect is registered")
(assert (= "?" ((d :placeholder) 1)) "MySQL's placeholder is positional-free")
(assert (= "`users`" ((d :quote) "users"))
        (string "identifiers are backticked: a double quote is an identifier "
                "quote only under ANSI_QUOTES and a string literal otherwise, "
                "so quoting the ANSI way would compile differently depending "
                "on a server setting"))
(assert (= "`we``ird`" ((d :quote) "we`ird")) "and an embedded backtick is doubled")

(assert (= "int auto_increment" (get-in d [:types :serial]))
        (string "NOT MySQL's own SERIAL, which expands to BIGINT UNSIGNED NOT "
                "NULL AUTO_INCREMENT UNIQUE — the UNIQUE it hides would collide "
                "with the PRIMARY KEY every declaration puts next to it"))
(assert (= "varchar(255)" (get-in d [:types :string]))
        "a :string is indexable, because MySQL will not index a TEXT without a length")
(assert (= "text" (get-in d [:types :text])) "while :text stays the document you do not index")
(assert (= "timestamp" (get-in d [:types :timestamptz]))
        "MySQL's TIMESTAMP is the one that normalizes to UTC, which is what timestamptz means")
(assert (= "datetime" (get-in d [:types :timestamp])) "and DATETIME is the wall clock")

# what a declaration compiles to, end to end
(def [ddl _] (builder/format {:create-table :posts
                              :columns [[:id :serial {:primary-key true}]
                                        [:slug :string {:unique true}]
                                        [:body :text]
                                        [:live :bool {:default false}]
                                        [:at :timestamptz]]}
                             :mysql))
(assert (string/find "`id` int auto_increment PRIMARY KEY" ddl))
(assert (string/find "`slug` varchar(255) UNIQUE" ddl))
(assert (string/find "`live` boolean DEFAULT FALSE" ddl)
        "a false default is a default — `(in opts :default)` would have dropped it")

(def [sql params] (builder/format {:select [:*] :from :posts
                                   :where [:= :slug "a"] :limit 10 :offset 20}
                                  :mysql))
(assert (= "SELECT * FROM `posts` WHERE `slug` = ? LIMIT ? OFFSET ?" sql))
(assert (deep= ["a" 10 20] params))

(def [offset-only _] (builder/format {:select [:*] :from :posts :offset 20} :mysql))
(assert (string/find "LIMIT 18446744073709551615 OFFSET" offset-only)
        (string "an OFFSET with no LIMIT is a syntax error on MySQL, and the "
                "dialect carries the largest-BIGINT LIMIT its manual prescribes"))

# -- phases 1-5, with no client library ----------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the kernel and the driver compose")
(assert (index-of :db.mysql/driver (report :components)) "the driver is in the graph")
(assert (index-of :db/pool (report :components)) "and the pool stands on it")

(def [ok err]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:db-mysql {:ssl-mode :whenever}})})))
(assert (not ok) "a config value outside the schema fails before anything starts")

(def [ok2 err2]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:db-mysql {:port 99999}})})))
(assert (not ok2) "and so does a port that is not one")

# -- the manifest --------------------------------------------------------

(assert (empty? mysql/defaults)
        (string "the slice declares no kernel-merged defaults: a merged "
                "default is indistinguishable from a choice, and would beat "
                "the same key inside a deployment's connection URL"))
(assert (= "utf8mb4" (mysql/fallbacks :charset)) "the real values are fallbacks")
(assert (mysql/fallbacks :found-rows))
(assert (not (mysql/library-available?))
        (string "and none of the above opened libmysqlclient in this VM — the "
                "driver opens it inside a worker thread and nowhere else "
                ", which is what lets this file run on a machine "
                "that has no MySQL at all"))

# -- against a real server -----------------------------------------------

(if-not (server/available?)
  (do (server/skip "db-mysql plugin (start!)")
      (print "db-mysql plugin-test ok")
      (os/exit 0)))

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:db-mysql (server/config)})}))

(defer (plugin/shutdown! boot 5)
  (def drv (get-in boot [:system :instances :db.mysql/driver]))
  (assert drv "the component started")
  (assert (= :mysql (drv :dialect)))
  (assert (false? (drv :returning))
          "MySQL has no RETURNING, so the entity layer re-reads by insert id")

  (def health ((get-in boot [:system :components :db.mysql/driver :health]) drv))
  (assert (= :up (health :status)) "health pings the keeper connection")
  (assert (health :server) "and reports what it connected to")

  # the pool is what the rest of void talks to, and it is fed by this
  # driver without the kernel naming MySQL anywhere
  (assert (= 1 (db/value ["SELECT 1 AS n" []])))

  (def table (server/table-name "plugin"))
  (defer (db/execute-sql (string "DROP TABLE IF EXISTS `" table "`") [] {:kind :write})
    # statement MAPS, not pre-formatted SQL: the pool compiles them with
    # the dialect its driver named, so this is also the assertion that
    # the kernel picked :mysql without anyone telling it to
    (db/execute! {:create-table (keyword table)
                  :columns [[:id :serial {:primary-key true}]
                            [:slug :string {:unique true}]
                            [:live :bool {:default false}]]})
    (db/execute! {:insert (keyword table) :values {:slug "a"}})
    (def row (db/one-row {:select [:*] :from (keyword table) :where [:= :slug "a"]}))
    (assert (= "a" (row :slug)) "a declaration round-trips through the real engine")
    (assert (= false (row :live))
            "and a DEFAULT FALSE that the builder now emits arrives as false")

    # the pool really is several connections, and therefore several
    # threads, all answering at once
    (def fibers (seq [i :range [0 4]]
                  (ev/go (fn [] (db/value ["SELECT SLEEP(0.2) + 1 AS n" []])))))
    (def t0 (os/clock :monotonic))
    (while (some |(not= :dead (fiber/status $)) fibers) (ev/sleep 0.01))
    (assert (< (- (os/clock :monotonic) t0) 0.7)
            (string "four 0.2s queries through a pool of two took under 0.7s — "
                    "two at a time, in parallel, rather than four in a row"))))

(print "db-mysql plugin-test ok")
