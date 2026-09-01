### The wave-3 half of the demo (wave 3): signing in, a
### row-level policy, and the CSRF token nobody had to write a line for.
###
### Like ./crud-test it is a function of the database and runs once per
### engine — sqlite always, Postgres when VOID_TEST_PG names a server —
### because "the same application on either engine" has to keep being
### true of the parts wave 3 added, not only of the CRUD.
###
### The first section boots nothing at all: a policy is a pure function
### of a context (ADR-0024 §1), so the cases that matter are a table,
### and everything after that is about the wiring around it.

(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/db :as db)
(import void/auth :as auth)
(import void/authz :as authz)
(import void/authz/policy :as policy)
(import void/jobs :as jobs)
(import void/mail :as mail)
(import ../main)
(import ../app)
(import ../entities :as e)

# -- the policy, with no system anywhere ---------------------------------

(defn- ctx-for [subject resource]
  (authz/make-context {:subject (when subject (auth/identity subject))
                       :resource resource}))

(def own (get (policy/lookup :articles/own) :fn))

(assert own "app.janet registered :articles/own by loading")
(assert (= true (own (ctx-for "author:7" {:author-id 7})))
        "the author of the row may act on it")
(assert (string? (own (ctx-for "author:7" {:author-id 9})))
        "another author may not, and the policy says why — for the log, never for the page")
(assert (string? (own (ctx-for nil {:author-id 7})))
        "and neither may nobody")
(assert (string? (own (ctx-for "author:7" {})))
        "a row with no author is not owned by anybody")

# -- the engines ---------------------------------------------------------

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-blog-auth-" (os/time) ".sqlite3"))

(def engines
  (filter identity
    [{:label "sqlite" :database :sqlite :config {:db-sqlite {:path sqlite-path}}}
     (when (pg/available?)
       {:label "postgres" :database :postgres
        :config {:db-postgres (pg/config)
                 :jobs-db {:table "blog_auth_test_jobs"}}})]))

(def app-tables
  ["audit_events" "comments" "articles" "authors"
   "auth_challenges" "auth_tokens" "schema_migrations"])

(defn- drop-app-tables! []
  (each t app-tables
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

(defn- text [resp] (test/text resp))

(defn- token-of [resp]
  (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`))) (text resp))))

(defn run-suite [engine]
  (def label (engine :label))
  (defn note [msg] (print "  [" label "] " msg))

  (def opts
    {:plugins (main/plugins (engine :database))
     :profile :test
     :config {:env @{}
              :cli (merge {:db {:n1-guard :strict :migrations {:dir "db/migrations"}}
                           :cache {:prefix (string "blog-auth-" label ":")}
                           # the demo's own cost, lowered: this suite
                           # registers and signs in a dozen times, and
                           # what scrypt costs is pinned in void/crypto
                           :auth {:scrypt {:ln 10}}
                           :crypto {:kdf {:in-thread false}}
                           # the letters this suite reads back; the
                           # application's own default writes .eml
                           # files, which is right for `void dev` and
                           # useless to an assertion
                           :mail {:transport :memory}}
                          (engine :config))}})

  (test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                         :crypto/lib :auth/registry :authz/registry
                                         # 3.6: every write announces
                                         # itself on the bus, in the
                                         # transaction that made it
                                         :bus/broker :bus.db/schema]})]
    (drop-app-tables!)
    (db/migrate-up! {:dir "db/migrations"})

    # -- every route names a policy --------------------------------------
    #
    # The application boots under [:authz :default :deny], so this is
    # already proven — a route without a policy would have failed the
    # boot rather than served traffic (ADR-0024 §6). Asserting it here
    # says which routes those are.
    (each route ((http/routes-table) :routes)
      (assert (not (empty? (get-in route [:meta :void.authz/policy] [])))
              (string/format "route %q carries a policy" (route :name))))
    (note "deny-by-default: every route in the table names a policy")

    # -- registration ----------------------------------------------------

    (def home (test/inject c {:uri "/"}))
    (assert (string/find "Not signed in" (text home)))
    (assert (string/find "Create an account" (text home)))

    (assert (= 302 ((test/inject c {:uri "/register"
                                    :form {:name "Ada" :email "ada@example.com"
                                           :password "correct horse battery"}})
                    :status)))
    (def ada (db/one e/Author {:where [:= :email "ada@example.com"]}))
    (assert ada "the account is an author row")
    (assert (string/has-prefix? "$scrypt$" (ada :password-hash))
            "the column holds a PHC string, so the cost travels with the hash")
    (assert (not (string/find "correct horse" (ada :password-hash))))

    # a second account for the same address is refused, and says so.
    # From another browser: the first one is signed in now, and a
    # signed-in POST without a token is refused by CSRF before the
    # handler ever runs — which is the next section's business
    (def visitor (test/client (c :boot)))
    (def dup (test/inject visitor {:uri "/register"
                                   :form {:name "Ada again" :email "ada@example.com"
                                          :password "another password"}}))
    (assert (string/find "already has an account" (text dup)))
    (assert (= 1 (db/count e/Author)))
    (note "registration ok")

    # -- signing in ------------------------------------------------------

    (def signed (test/inject c {:uri "/"}))
    (assert (string/find "Signed in as" (text signed)) "registration signs the visitor in")
    (assert (string/find "Ada" (text signed)) "and the page greets them by the claim from the store")

    (def token (token-of signed))
    (assert token "the publish form carries a CSRF token")

    # :method, because test/inject infers POST from a body and this
    # request has none — a sign-out is a POST with nothing in it
    (assert (= 302 ((test/inject c {:method :post :uri "/sign-out"
                                    :headers {"x-csrf-token" token}})
                    :status)))
    (def signed-out (test/inject c {:uri "/"}))
    (assert (string/find "Not signed in" (text signed-out)))

    # the sign-in form carries a token like every other form: the
    # visitor still has a session cookie (an empty one), so the request
    # is cookie-borne and void/security checks it
    (def anon-token (token-of signed-out))
    (defn- sign-in [email password]
      (test/inject c {:uri "/sign-in"
                      :headers {"x-csrf-token" anon-token}
                      :form {:email email :password password}}))

    (def wrong (sign-in "ada@example.com" "not it"))
    (assert (string/find "do not match" (text wrong)))
    (def unknown (sign-in "nobody@example.com" "not it"))
    (defn- message-of [resp]
      (first (peg/match ~(* (thru `class="message">`) (<- (to "<"))) (text resp))))
    (assert (= (message-of wrong) (message-of unknown))
            "a wrong password and an unknown address say exactly the same thing — telling them apart is a user-enumeration API, and check-password spends the same time on both")
    (assert (= (wrong :status) (unknown :status)))
    (each said ["no such" "unknown" "wrong password" "not registered"]
      (assert (not (string/find said (string/ascii-lower (text unknown))))
              (string "and the page does not say " said)))

    (assert (= 302 ((sign-in "ada@example.com" "correct horse battery") :status)))
    (note "sign-in ok")

    # -- CSRF ------------------------------------------------------------

    (def page (test/inject c {:uri "/"}))
    (def ada-token (token-of page))

    (def no-token (test/inject c {:uri "/articles"
                                  :form {:title "No token" :body "Should not land."}}))
    (assert (= 403 (no-token :status))
            "a signed-in POST without the token is refused: the credential rode on a cookie, which is exactly when CSRF applies")
    (assert (= 0 (db/count e/Article)))

    (assert (= 200 ((test/inject c {:uri "/articles"
                                    :headers {"x-csrf-token" ada-token}
                                    :form {:title "Fibers" :body "A first article."}})
                    :status)))
    (assert (= 1 (db/count e/Article)))
    (def article (db/one e/Article {:order-by [[:id :desc]]}))
    (def url (string "/articles/" (article :id)))
    (assert (= (ada :id) (article :author-id)))
    (note "csrf ok")

    # -- the row-level policy --------------------------------------------

    (def mine (test/inject c {:uri url}))
    (assert (string/find "Edit" (text mine))
            "the author sees the Edit control — the same policy the route enforces (ADR-0024)")

    (assert (= 200 ((test/inject c {:uri (string url "/edit")}) :status)))
    (assert (= 302 ((test/inject c {:uri url
                                    :headers {"x-csrf-token" ada-token}
                                    :form {:title "Fibers, revisited" :body (article :body)}})
                    :status)))
    (assert (= "Fibers, revisited" ((db/find e/Article (article :id)) :title)))

    # a second author, in a browser of their own
    (def other (test/client (c :boot)))
    (assert (= 302 ((test/inject other {:uri "/register"
                                        :form {:name "Grace" :email "grace@example.com"
                                               :password "another good password"}})
                    :status)))

    (def theirs (test/inject other {:uri url}))
    (assert (= 200 (theirs :status)) "another author may read the article")
    (assert (not (string/find "Edit" (text theirs)))
            "and is shown nothing to click — the control and the permission come from one source")

    (assert (= 403 ((test/inject other {:uri (string url "/edit")}) :status))
            "and asking for the form directly is a 403")

    (def grace-token (token-of (test/inject other {:uri "/"})))
    (def hijack (test/inject other {:uri url
                                    :headers {"x-csrf-token" grace-token}
                                    :form {:title "Mine now" :body "…"}}))
    (assert (= 403 (hijack :status)) "so is posting to it")
    (assert (= "Fibers, revisited" ((db/find e/Article (article :id)) :title))
            "and the row is untouched")

    (assert (= 403 ((test/inject other {:uri url :method :delete
                                        :headers {"x-csrf-token" grace-token}})
                    :status)))
    (assert (db/find e/Article (article :id)) "the article is still there")
    (note "row-level policy ok")

    # -- anonymous --------------------------------------------------------

    (def anon (test/client (c :boot)))
    (def redirected (test/inject anon {:uri (string url "/edit")}))
    (assert (= 302 (redirected :status))
            "an unauthenticated request to a protected route goes to the sign-in page, because this application said :redirect")
    (assert (string/has-prefix? "/?next=" (get-in redirected [:headers "location"]))
            "carrying where it was going")
    (assert (= 200 ((test/inject anon {:uri url}) :status)) "while reading stays open")
    (assert (= 200 ((test/inject anon {:uri (string url "/comments")
                                       :form {:author-name "Reader" :body "No account needed."}})
                    :status))
            "and so does commenting: the route says :public, which under deny-by-default is a statement rather than a silence")
    (note "anonymous ok")

    # -- the sign-in link ------------------------------------------------
    #
    # The last piece of the wave-3 exit criterion: the
    # application issues a challenge and says nothing else about it —
    # the letter, the URL and the one-time code belong to
    # void/mail-auth (ADR-0026 §6), and it goes out through the queue
    # this application already runs.

    (jobs/clear!)
    (mail/clear-outbox!)
    (def link-client (test/client (c :boot)))
    (def link-token (token-of (test/inject link-client {:uri "/"})))

    (defn- ask-for-link [email]
      (test/inject link-client {:uri "/sign-in/magic"
                                :headers {"x-csrf-token" link-token}
                                :form {:email email}}))

    (def asked (ask-for-link "ada@example.com"))
    (assert (string/find "on its way" (text asked)))
    (assert (empty? (mail/outbox))
            "nothing was sent on the request fiber: composing void/mail-jobs is the whole of \"through the queue\", and no handler mentions it")
    (assert (= 1 (length (jobs/list-jobs {:queue :mail :state :pending})))
            "the letter is a job in the same queue the counter runs in")

    (assert (= 1 (jobs/drain!)) "the worker sends it")
    (assert (= 1 (length (mail/outbox))))

    (def letter (get-in (mail/outbox) [0]))
    (assert (string/find "To: ada@example.com" (letter :bytes)))
    (assert (not (string/find "correct horse" (letter :bytes))))

    # the link, as a mail client would see it: undo the transfer
    # encoding, then read it out of the text part
    (def decoded (string/replace-all "=3D" "="
                                     (string/replace-all "=\r\n" "" (letter :bytes))))
    (def magic
      (first (peg/match ~(any (+ (<- (* "/auth/magic?h="
                                        (some (if-not (set "&\"< \r\n") 1))
                                        "&c="
                                        (some (if-not (set "&\"< \r\n") 1))))
                                 1))
                        decoded)))
    (assert magic "the letter carries the link")

    (def followed (test/inject link-client {:uri magic}))
    (assert (= 302 (followed :status)) "and following it signs the visitor in")
    (def as-ada (test/inject link-client {:uri "/"}))
    (assert (string/find "Signed in as" (text as-ada)))
    (assert (string/find "Ada" (text as-ada))
            "greeted by the claim that travelled on the challenge — no second query")

    (def again (test/inject (test/client (c :boot)) {:uri magic}))
    (assert (string/find "expired or has already been used" (text again))
            "a link works once: redeem takes the challenge out of the store before it checks the code")

    (jobs/clear!)
    (mail/clear-outbox!)
    (def stranger (ask-for-link "nobody@example.com"))
    (assert (= (message-of asked) (message-of stranger))
            "an address with no account gets the same page — anything else is a way to ask this blog who its authors are")
    (assert (empty? (jobs/list-jobs {:queue :mail}))
            "and no letter is queued for it")
    (note "magic link ok")

    # -- the decision log -------------------------------------------------

    (def decisions @[])
    (authz/listen! :test/spy (fn [d] (array/push decisions d)))
    (test/inject other {:uri (string url "/edit")})
    (authz/unlisten! :test/spy)
    (def denial (find |(not ($ :allow)) decisions))
    (assert denial "the deny went through the decision hook void/bus will subscribe to in 3.6")
    (assert (= :articles/own (denial :policy)))
    (assert (string/find "not the author" (denial :reason))
            "with the reason the page did not print")
    (note "decision log ok")

    (db/migrate-down! {:dir "db/migrations" :step 3})))

# -- run it once per engine ----------------------------------------------

(log/set-sinks! [(fn [_])])

(each engine engines
  (print "blog auth-test: " (engine :label))
  (run-suite engine))

(log/set-sinks! nil)
(os/rm sqlite-path)

(unless (pg/available?)
  (printf "blog auth-test: SKIPPED the Postgres pass (set %s to a conninfo or a postgres:// url)"
          pg/env-var))
(printf "blog auth-test ok (%s)" (string/join (map |($ :label) engines) ", "))
