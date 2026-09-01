### The wave-2 example is also its smoke test (wave-2 exit criteria 1
### and 3): a CRUD application on Postgres with migrations, background
### jobs and a cache — and the same application on sqlite with the
### driver swapped and nothing else.
###
### So the suite is a function of the database, run once per engine.
### sqlite always (a temporary file, nothing to install); Postgres when
### VOID_TEST_PG names a server, which in CI it does. Everything below
### the `run-suite` line is engine-agnostic on purpose: if a single
### assertion needed a `case` on the dialect, the claim would be false.
###
### Requests go through test/inject (ADR-0017) — the production stack
### without a socket: routing, lifecycle stages, middleware, schema
### validation, the :void.db/txn wrapper, rendering, wire bytes.

(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/cache :as cache)
(import void/jobs :as jobs)
(import void/auth :as auth)
(import ../main)
(import ../entities :as e)
(import ../jobs :as blog-jobs)

# -- what the two passes differ by ---------------------------------------

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-blog-test-" (os/time) ".sqlite3"))



(def engines
  (filter identity
    [{:label "sqlite"
      :database :sqlite
      :config {:db-sqlite {:path sqlite-path}}}
     (when (pg/available?)
       {:label "postgres"
        :database :postgres
        :config {:db-postgres (pg/config)
                 # the queue lives in the same database as the data;
                 # a table of its own keeps a shared test server from
                 # tripping over another suite's records
                 :jobs-db {:table "blog_test_jobs"}}})]))

(def app-tables
  "Dropped before every pass, newest first — the suite owns the schema."
  [# 3.6's own, created by the migration the audit trail needs
   "audit_events"
   "comments" "articles" "authors"
   # void/auth-db's two tables, created by the wave-3 migration from
   # `(auth-db/tables)` — DDL the plugin ships as data
   "auth_challenges" "auth_tokens"
   "schema_migrations"])

(defn- drop-app-tables! []
  (each t app-tables
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

# -- the suite -----------------------------------------------------------

(defn- text [resp] (test/text resp))

(defn run-suite [engine]
  (def label (engine :label))
  (defn note [msg] (print "  [" label "] " msg))

  (def opts
    {:plugins (main/plugins (engine :database))
     :profile :test
     :config {:env @{}
              :cli (merge {# an unpreloaded relation is an error here,
                           # not a warning: the application must not
                           # have a single one (ADR-0009)
                           :db {:n1-guard :strict
                                :migrations {:dir "db/migrations"}}
                           :cache {:prefix (string "blog-test-" label ":")}}
                          (engine :config))}})

  # the composition is valid before anything starts
  (def report (plugin/dry-run opts))
  (assert (report :ok) (string label ": dry-run passes"))

  # wave 3 put three more components in the subset: the library every
  # token is signed with, the auth registry the login path reads its
  # stores from, and the policy registry the routes enforce through.
  # 3.6 put two more: the broker every write announces itself on, and
  # the schema component that creates the log it announces itself into
  # — a handler that calls `bus/publish-tx!` in a composition without a
  # bus fails the write, which is the correct answer and not one a test
  # should be discovering
  (test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                         :crypto/lib :auth/registry :authz/registry
                                         :bus/broker :bus.db/schema]})]

    # -- migrations ------------------------------------------------------
    (drop-app-tables!)
    (jobs/clear!)

    (def pending (db/migration-status "db/migrations"))
    (assert (= 4 (length pending)) "four migrations on disk")
    (assert (not (some |($ :applied) pending)) "none applied yet")

    (def applied (db/migrate-up! {:dir "db/migrations"}))
    (assert (= 4 (length applied)) "all four applied")
    (assert (all |($ :applied) (db/migration-status "db/migrations"))
            "and the version table says so")
    (note "migrations applied")

    # -- create: one form, two entities, one transaction -----------------

    (def empty-page (test/inject c {:uri "/"}))
    (assert (= 200 (empty-page :status)))
    (assert (string/find "Nothing published yet" (text empty-page)))
    (assert (string/find "Sign in" (text empty-page))
            "wave 3: an anonymous visitor is offered a way in, not a publish form")
    (assert (not (string/find `name="title"` (text empty-page)))
            "and cannot publish")

    (assert (= 302 ((test/inject c {:uri "/articles" :form {:title "x" :body "y"}}) :status))
            "posting anyway is a redirect to the sign-in page (:void.auth/access :required)")
    (assert (= 0 (db/count e/Article)) "and nothing was written")

    # -- signing in ------------------------------------------------------

    (def registered
      (test/inject c {:uri "/register"
                      :form {:name "Ada" :email "ada@example.com"
                             :password "correct horse battery"}}))
    (assert (= 302 (registered :status)) (text registered))
    (assert (= 1 (db/count e/Author)) "the account is an author row")
    (def ada (db/one e/Author {:where [:= :email "ada@example.com"]}))
    (assert (string/has-prefix? "$" (ada :password-hash))
            "with a PHC string in the column, not a password")

    (def signed-in (test/inject c {:uri "/"}))
    (assert (string/find "Signed in as" (text signed-in)))
    (assert (string/find `name="title"` (text signed-in))
            "and now the schema-driven publish form is on the page")

    # every non-GET request from here on carries the CSRF token: the
    # session cookie makes the credential cookie-borne, which is
    # exactly when void/security checks (ADR-0025 §1). The token is on
    # the page because form/form splices it — the application asked for
    # nothing
    (def token
      (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`)))
                        (text signed-in))))
    (assert token "the form carries a CSRF token")
    (defn- post [uri &opt spec]
      (test/inject c (merge {:uri uri :headers {"x-csrf-token" token}} (or spec {}))))
    (note "sign-in ok")

    # -- create ----------------------------------------------------------

    (def bad (post "/articles" {:form {:title "" :body ""}}))
    (assert (string/find "field-errors" (text bad))
            "schema errors land next to their fields")
    (assert (= 0 (db/count e/Article)) "and nothing was written")

    (def created
      (post "/articles" {:headers {"hx-request" "true" "x-csrf-token" token}
                         :form {:title "Fibers all the way down"
                                :body "A first article."}}))
    (assert (= 200 (created :status)) (text created))
    (assert (not (string/find "<html" (text created)))
            ":void.htmx/partial answers htmx with the bare fragment")
    (assert (string/find "Fibers all the way down" (text created)))
    (assert (= 1 (db/count e/Article)) "the article is stored")

    (def article (db/one e/Article {:order-by [[:id :desc]]}))
    (def article-url (string "/articles/" (article :id)))
    (assert (= (ada :id) (article :author-id))
            "and it belongs to whoever was signed in — the author is not a form field any more")

    (post "/articles" {:form {:title "Second" :body "More."}})
    (assert (= 2 (db/count e/Article)))
    (assert (= 1 (db/count e/Author)) "still one account")
    (note "create ok (the author is the identity)")

    # -- read: preloads, and the guard that proves they are there --------

    (def shown (test/inject c {:uri article-url}))
    (assert (= 200 (shown :status)))
    (assert (string/find "by Ada" (text shown)) "the author is preloaded")
    (assert (string/find "No comments yet" (text shown)))

    (assert (= 404 ((test/inject c {:uri "/articles/999999"}) :status))
            "a missing article is a 404, not a 500")

    # the guard is real: reaching for an unpreloaded relation throws
    (def bare (db/find e/Article (article :id)))
    (assert (not (first (protect (db/rel bare :comments))))
            "an unplanned relation is an error under :strict (ADR-0009)")
    (def loaded (db/find e/Article (article :id) {:preload [:author :comments]}))
    (assert (deep= [] (db/rel loaded :comments))
            "and a preloaded one is a table lookup")
    (assert (= "Ada" ((db/rel loaded :author) :name))
            "and so is a preloaded belongs-to")
    (note "N+1 guard ok")

    # -- the cache: the index is read once -------------------------------

    (cache/clear!)
    (test/inject c {:uri "/"})
    (def after-first (cache/stats))
    (test/inject c {:uri "/"})
    (def after-second (cache/stats))
    (assert (= (inc (after-first :hits)) (after-second :hits))
            "the second index render came out of the cache")
    (note "cache ok")

    # -- update: dirty tracking writes the diff and nothing else ---------

    (def edit-page (test/inject c {:uri (string article-url "/edit")}))
    (assert (string/find "Fibers all the way down" (text edit-page))
            "the edit form is filled from the entity")

    (def updated (post article-url {:form {:title "Fibers, revisited"
                                           :body (article :body)}}))
    (assert (= 302 (updated :status)) "a form post redirects to the article")
    (def again (db/find e/Article (article :id)))
    (assert (= "Fibers, revisited" (again :title)))

    (assert (not (db/dirty? again)) "a freshly loaded instance is clean")
    (assert (empty? (db/changes again)) "so it has no diff to write")
    (assert (= again (db/save! again))
            "and save! on it is a no-op, not an UPDATE of every column")
    (put again :title "Fibers, once more")
    (assert (deep= @{:title "Fibers, once more"} (db/changes again))
            "changes are the diff against the load-time snapshot")
    (db/save! again)
    (assert (not (db/dirty? again)) "and the snapshot moves on")
    (note "dirty tracking ok")

    # -- comments: the counter is a background job -----------------------

    (jobs/clear!)
    (cache/clear!)
    (def commented
      (post (string article-url "/comments")
            {:headers {"hx-request" "true" "x-csrf-token" token}
             :form {:author-name "Grace" :body "Nice one."}}))
    (assert (= 200 (commented :status)))
    (assert (string/find "Nice one." (text commented)) "the comment is rendered")
    (assert (string/find "0 counted" (text commented))
            "and the counter still trails it — the job has not run yet")

    (def queued (jobs/list-jobs {:queue :maintenance}))
    (assert (= 1 (length queued)) "one recount is queued")
    (assert (= :recount-comments ((first queued) :job)))

    # a burst on the same article collapses into the one run (:unique :args)
    (post (string article-url "/comments")
          {:form {:author-name "Grace" :body "And again."}})
    (assert (= 1 (length (jobs/list-jobs {:queue :maintenance :state :pending})))
            ":unique :args collapsed the second enqueue into the first")

    (assert (= 1 (jobs/drain!)) "the worker ran it once")
    (assert (= 2 ((db/find e/Article (article :id)) :comment-count))
            "and the counter caught up with both comments")

    (def counted (test/inject c {:uri article-url}))
    (assert (string/find "2 counted" (text counted)))
    (assert (nil? (cache/get blog-jobs/index-cache-key))
            "the job dropped the cached index it invalidated")
    (note "background job ok")

    # -- delete: the comments go with it ---------------------------------

    (def gone (post article-url {:method :delete}))
    (assert (or (= 204 (gone :status)) (= 302 (gone :status))))
    (assert (nil? (db/find e/Article (article :id))) "the article is gone")
    (assert (= 0 (db/count e/Comment {:where [:= :article-id (article :id)]}))
            "and its comments went with it (ON DELETE CASCADE)")
    (note "delete ok")

    # -- the ERD is a projection of the same declarations ----------------

    (def diagram (db/erd-mermaid [:Author :Article :Comment]))
    (assert (string/find "erDiagram" diagram))
    (each name ["Author {" "Article {" "Comment {"]
      (assert (string/find name diagram) (string "erd names " name)))
    (assert (string/find "Author" diagram))
    (assert (string/find "||--o{" diagram) "has-many relations are drawn")
    (note "erd ok")

    # -- migrations roll back --------------------------------------------

    (def reverted (db/migrate-down! {:dir "db/migrations" :step 4}))
    (assert (= 4 (length reverted)) "every migration rolled back")
    (assert (not (some |($ :applied) (db/migration-status "db/migrations")))
            "the version table is empty again")
    (note "rollback ok")))

# -- run it once per engine ----------------------------------------------

(log/set-sinks! [(fn [_])])

(each engine engines
  (print "blog crud-test: " (engine :label))
  (run-suite engine))

(log/set-sinks! nil)
(os/rm sqlite-path)

(unless (pg/available?)
  (printf "blog crud-test: SKIPPED the Postgres pass (set %s to a conninfo or a postgres:// url)"
          pg/env-var))
(printf "blog crud-test ok (%s)"
        (string/join (map |($ :label) engines) ", "))
