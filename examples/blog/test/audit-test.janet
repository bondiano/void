### The 3.6 half of the demo, and exit criterion 1 of wave 3: **audit
### through the bus**.
###
### What is being demonstrated is not that a row gets written — any
### `db/insert!` in a handler would do that. It is the shape:
###
###   * the handlers publish *facts*, and know nothing about auditing;
###   * the fact rides the transactional outbox, so the trail and the
###     row it describes commit together — a rolled-back write leaves
###     no line claiming it happened, and a committed one cannot fail
###     to leave one;
###   * void/authz's refusals reach the same trail through the hook it
###     has fired since 3.3, with no middleware and no wrapper;
###   * the consumer is a `defhandler` in its own group, and deleting
###     ./audit stops the trail and changes nothing else.
###
### Like ./crud-test and ./auth-test it runs once per engine — sqlite
### always, Postgres when VOID_TEST_PG names a server.

(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/bus :as bus)
(import void/bus/db :as busdb)
(import void/bus/state :as bus-state)
(import ../main)
(import ../app)
(import ../audit :as audit)
(import ../entities :as e)

(def bus-table
  "The bus's own tables in this suite — the default name, since the
  suite drops and recreates them (see `reset-bus!`)."
  "void_bus")

(defn- reset-bus!
  ``Take the message log, the cursors and the outbox back to empty.

  A consumer group's cursor is *state*: left over from the last run it
  is a consumer that has already read everything this one publishes,
  and every assertion below would pass for the wrong reason. The
  application's own tables are dropped and re-migrated for exactly the
  same reason a line above.``
  []
  (each t [bus-table (string bus-table "_cursors")
           (string bus-table "_leases") (string bus-table "_outbox")]
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) []
                    {:kind :write :prepared false}))
  (busdb/create-tables! bus-table))

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-blog-audit-" (os/time) ".sqlite3"))

(def engines
  (filter identity
    [{:label "sqlite" :database :sqlite :config {:db-sqlite {:path sqlite-path}}}
     (when (pg/available?)
       {:label "postgres" :database :postgres
        :config {:db-postgres (pg/config)
                 :jobs-db {:table "blog_audit_test_jobs"}
                 # the whole slice, because `merge` below replaces a
                 # key rather than deepening it — and a poll interval
                 # left at its one-second default is a suite that waits
                 # for a second it never said it was waiting for
                 :bus-db {:table bus-table
                          :poll-interval 0.05
                          :forwarder {:enabled false}}}})]))

(def app-tables
  ["audit_events" "comments" "articles" "authors"
   "auth_challenges" "auth_tokens" "schema_migrations"])

(defn- drop-app-tables! []
  (each t app-tables
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

(defn- text [resp] (test/text resp))

(defn- token-of [resp]
  (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`))) (text resp))))

(defn- settle
  ``Forward whatever the outbox holds and let the consumer catch up.
  In a deployment this is the `:bus.db/forwarder` component and the
  consumer's own poll; in a test it is a call and a sleep, so that
  what is asserted is the *trail*, not the timing.``
  []
  (busdb/forward-once! (bus-state/active-backend) 100)
  (ev/sleep 0.3))

(defn run-suite [engine]
  (def label (engine :label))
  (defn note [msg] (print "  [" label "] " msg))

  (def opts
    {:plugins (main/plugins (engine :database))
     :profile :test
     :config {:env @{}
              :cli (merge {:db {:migrations {:dir "db/migrations"}}
                           :cache {:prefix (string "blog-audit-" label ":")}
                           :auth {:scrypt {:ln 10}}
                           :crypto {:kdf {:in-thread false}}
                           :mail {:transport :memory}
                           # the consumer polls fast, and the forwarder
                           # is driven by hand (see `settle`) so that
                           # nothing here waits on a timer it does not
                           # control
                           # the consumers are started by hand below,
                           # once the schema this suite writes into
                           # actually exists: a consumer that starts
                           # with the system would be reading a log
                           # while the suite is dropping the tables it
                           # writes into, which is a race the test
                           # would own rather than the bus
                           :bus {:consume false}
                           :bus-db {:poll-interval 0.05
                                    :forwarder {:enabled false}}}
                          (engine :config))}})

  (test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                         :crypto/lib :auth/registry :authz/registry
                                         :bus/broker :bus.db/schema]})]
    (drop-app-tables!)
    (db/migrate-up! {:dir "db/migrations"})
    (reset-bus!)
    (bus/start-consumers! (bus-state/active))

    (assert (bus-state/active) "the bus is up")
    (assert (get (bus/stats) :outbox)
            "and void/bus-db installed the outbox writer, which is what publish-tx! needs")
    (assert (index-of :record-audit (bus/handlers))
            "./audit declared a consumer by being loaded, and nothing else did anything")

    # -- register and sign in ---------------------------------------------

    (assert (= 302 ((test/inject c {:uri "/register"
                                    :form {:name "Ada" :email "ada@example.com"
                                           :password "correct horse battery"}})
                    :status))
            "registering signs the visitor in")

    (defn post [uri form]
      (def token (token-of (test/inject c {:uri "/"})))
      (test/inject c {:uri uri :headers {"x-csrf-token" token} :form form}))

    # -- a committed write leaves a line ----------------------------------

    (def published (post "/articles" {:title "Fibers" :body "A first article."}))
    (assert (= 200 (published :status)))

    (def article (db/one e/Article {:where [:= :title "Fibers"]}))
    (assert article)

    # before the forwarder runs the trail is empty and the article
    # exists: the message is committed, in a table, waiting
    (assert (empty? (audit/trail))
            "the fact is in the outbox, not yet on the bus — which is exactly what an outbox is")

    (settle)
    (def trail (audit/trail))
    (def published-line (find |(= "article/published" ($ :topic)) trail))
    (assert published-line "the trail has the fact the handler published")
    (assert (= "author:1" (published-line :actor)) "with who did it")
    (assert (string/find "Fibers" (published-line :detail)))
    (note "a committed write is on the trail")

    # -- and a rolled-back one does not -----------------------------------
    #
    # The route is :void.db/txn true, so a handler that throws rolls the
    # transaction back — and the audit message is *in* that transaction.
    # An empty title fails validation rather than throwing, so the write
    # that must not be audited is made here directly, the way the
    # handler would.

    (def before (length (audit/trail)))
    (def [ok _]
      (protect
        (db/with-tx
          (db/insert! e/Article {:author-id 1 :title "Never" :body "b"
                                 :comment-count 0 :created-at (e/now)})
          (audit/record-tx! :article/published "author:1" {:article 999 :title "Never"})
          (error "the business rule said no"))))
    (assert (not ok))
    (settle)
    (assert (= before (length (audit/trail)))
            "a rolled-back write leaves no line claiming it happened")
    (assert (nil? (db/one e/Article {:where [:= :title "Never"]}))
            "and the row it would have described is not there either")
    (note "a rolled-back write leaves no trail")

    # -- a comment, published by a handler that mentions no audit ---------

    (def commented
      (post (string "/articles/" (article :id) "/comments")
            {:author-name "Grace" :body "Nice."}))
    (assert (= 200 (commented :status)))
    (settle)
    (assert (find |(= "comment/posted" ($ :topic)) (audit/trail)))
    (note "a comment is on the trail")

    # -- a refusal reaches the same trail ---------------------------------
    #
    # Through the hook void/authz has fired since 3.3 and nothing else:
    # no middleware, no wrapper, and no change to any route.

    # a *second author*, not an anonymous visitor: authentication is
    # phase 4000 and authorization 5000, so a visitor who is not signed
    # in is redirected before any policy is consulted and there is no
    # decision to audit. The interesting refusal is the one a signed-in
    # somebody-else gets
    (def grace (test/client (c :boot)))
    (test/inject grace {:uri "/register"
                        :form {:name "Grace" :email "grace@example.com"
                               :password "another good password"}})
    (def other (test/inject grace {:uri "/"}))
    (def denied
      (test/inject grace {:uri (string "/articles/" (article :id))
                          :headers {"x-csrf-token" (token-of other)}
                          :form {:title "Hijacked" :body "b"}}))
    (assert (= 403 (denied :status)) "another author may not edit Ada's article")
    (ev/sleep 0.3)
    (def refusals (filter |(= "authz/denied" ($ :topic)) (audit/trail)))
    (assert (not (empty? refusals))
            "and the refusal is on the trail, published straight rather than through the outbox — a refused request wrote nothing to be consistent with")
    (note "a refusal is on the trail")

    # -- one request, one correlation -------------------------------------

    (def line (find |(= "comment/posted" ($ :topic)) (audit/trail)))
    (assert (string? (line :correlation-id)))
    (assert (not (empty? (audit/trail {:correlation-id (line :correlation-id)})))
            "the trail is answerable to 'what happened when that button was pressed'")

    # -- a redelivery does not double a line ------------------------------
    #
    # At-least-once is what the backend promises, so the consumer has to
    # be idempotent; here that is the unique index on message_id doing
    # the saying, which is the cheapest honest way.

    (def n (length (audit/trail)))
    (def msg (bus/publish :article/published {:actor "author:1" :article 1 :title "Twice"}))
    (ev/sleep 0.3)
    (assert (= (inc n) (length (audit/trail))))
    (assert (= :already-recorded (audit/record-audit msg))
            "handing the same message over again records nothing new")
    (assert (= (inc n) (length (audit/trail))))
    (note "a redelivery does not double a line")

    # -- and the queue's own life is on it too ----------------------------
    #
    # void/bus-jobs, which nothing in this application mentions.

    (bus/publish :jobs/completed {:job "recount-comments" :queue "maintenance"})
    (ev/sleep 0.3)
    (assert (find |(= "jobs/completed" ($ :topic)) (audit/trail))
            "the queue's lifecycle reaches the trail without the application asking")
    (note "the queue's lifecycle is on the trail")))

# -- run it once per engine ----------------------------------------------



# the suite provokes a duplicate-key error on purpose (the redelivery
# case), so the sinks go quiet the way the other blog suites' do
(log/set-sinks! [(fn [_])])

(each engine engines
  (print "blog audit-test: " (engine :label))
  (run-suite engine))

(log/set-sinks! nil)
(os/rm sqlite-path)

(unless (pg/available?)
  (printf "blog audit-test: SKIPPED the Postgres pass (set %s to a conninfo or a postgres:// url)"
          pg/env-var))
(printf "blog audit-test ok (%s)"
        (string/join (map |($ :label) engines) ", "))
