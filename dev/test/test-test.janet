(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/schema :as schema)
(import void/test :as test)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat)))

# a small app: db <- repo <- web, plus an unrelated mailer
(def log @[])
(defn- track [key inst]
  (fn [d c] (array/push log [:start key]) inst))
(def app
  (plugin/manifest 'test/app
    :components [(system/component :app/db
                   :start (track :app/db @{:kind :real-db})
                   :stop (fn [i] (array/push log [:stop :app/db])))
                 (system/component :app/repo
                   :deps [:app/db]
                   :start (fn [d c]
                            (array/push log [:start :app/repo])
                            @{:db (d :app/db)})
                   :stop (fn [i] (array/push log [:stop :app/repo])))
                 (system/component :app/web
                   :deps [:app/repo]
                   :start (track :app/web :web)
                   :stop (fn [i] (array/push log [:stop :app/web])))
                 (system/component :app/mailer
                   :start (track :app/mailer :mailer)
                   :stop (fn [i] (array/push log [:stop :app/mailer])))]))

# -- :only starts the subset plus transitive deps ------------------------

(def boot (test/start! {:plugins [app] :only [:app/repo]}))
(assert (= :test (boot :profile)) "test profile is the default")
(assert (= [[:start :app/db] [:start :app/repo]] (freeze log))
        ":only brings transitive deps and nothing else")
(assert (nil? (get-in boot [:system :components :app/web]))
        "unneeded components are not even in the graph")
(test/stop! boot)
(assert (= [[:stop :app/repo] [:stop :app/db]] (freeze (slice log 2)))
        "stop! reverses the order")

# -- :components overrides = stubs ---------------------------------------

(array/clear log)
(def stub-db (system/component :app/db
               :start (fn [d c] @{:kind :stub-db})))
(test/with-system [b2 {:plugins [app]
                       :only [:app/repo]
                       :components [stub-db]}]
  (def repo (system/instance (b2 :system) :app/repo))
  (assert (= :stub-db (get-in repo [:db :kind]))
          "the stub replaces the real component for dependents"))
(assert (= [:stop :app/repo] (log (- (length log) 1)))
        "with-system stopped the system on exit")

# -- with-system stops even when the body throws -------------------------

(array/clear log)
(def [ok _]
  (protect
    (test/with-system [b3 {:plugins [app] :only [:app/db]}]
      (error "test body boom"))))
(assert (not ok))
(assert (deep= log @[[:start :app/db] [:stop :app/db]])
        "with-system stops the system on body error")

# -- validation ----------------------------------------------------------

(expect-error "unknown option" "unknown option"
  |(test/start! {:plugins [app] :onyl [:app/db]}))
(expect-error "unknown :only key" "unknown component"
  |(test/start! {:plugins [app] :only [:app/nope]}))

# -- factories -----------------------------------------------------------

(schema/register! :test/User
  {:email [:string {:format :email}]
   :age [:int {:min 18 :max 99}]
   :role [:enum :admin :user]})

(def u (test/factory :test/User))
(assert (schema/valid? :test/User u))

(def u2 (test/factory :test/User :email "fixed@example.com" :age 33))
(assert (= "fixed@example.com" (u2 :email)) "overrides win")
(assert (= 33 (u2 :age)))
(assert (schema/valid? :test/User u2))

(expect-error "odd overrides" "key-value" |(test/factory :test/User :email))
(expect-error "overrides on non-map" "map schema" |(test/factory :int :a 1))

(assert (schema/valid? :test/User (test/generate :test/User))
        "generate is re-exported")

# -- snapshots -----------------------------------------------------------

(def snap-dir "test/tmp-snapshots")
(defn- rm-rf [dir]
  (when (os/stat dir)
    (each f (os/dir dir) (os/rm (string dir "/" f)))
    (os/rmdir dir)))
(rm-rf snap-dir)

(assert (= :created (test/snapshot "greeting" "<h1>hi</h1>" snap-dir))
        "a missing snapshot is created")
(assert (= "<h1>hi</h1>" (string (slurp (string snap-dir "/greeting.snap")))))
(assert (= :matched (test/snapshot "greeting" "<h1>hi</h1>" snap-dir)))
(assert (= :matched (test/snapshot "greeting" @"<h1>hi</h1>" snap-dir))
        "buffers compare by content")
(expect-error "snapshot mismatch" "differs"
  |(test/snapshot "greeting" "<h1>bye</h1>" snap-dir))
(assert (= :updated (do (os/setenv "VOID_SNAPSHOT_UPDATE" "1")
                        (defer (os/setenv "VOID_SNAPSHOT_UPDATE" nil)
                          (test/snapshot "greeting" "<h1>bye</h1>" snap-dir))))
        "VOID_SNAPSHOT_UPDATE rewrites")
(assert (= :matched (test/snapshot "greeting" "<h1>bye</h1>" snap-dir)))

(rm-rf snap-dir)

# -- service: the gate every live-server suite stands behind ----------------

(def gate (test/service "VOID_TEST_TEST_SERVICE" "a test:// url"))
(assert (= "VOID_TEST_TEST_SERVICE" (gate :env-var)))
(os/setenv "VOID_TEST_TEST_SERVICE" nil)
(assert (nil? ((gate :value))) "unset: no value")
(assert (not ((gate :available?))) "and nothing to test against")
(os/setenv "VOID_TEST_TEST_SERVICE" "   ")
(assert (nil? ((gate :value))) "blank is unset — a stray space in CI is not a server")
(assert (not ((gate :available?))))
(os/setenv "VOID_TEST_TEST_SERVICE" " test://127.0.0.1:1/9 ")
(assert (= "test://127.0.0.1:1/9" ((gate :value))) "trimmed")
(assert ((gate :available?)))
(os/setenv "VOID_TEST_TEST_SERVICE" nil)
(def announced
  (let [buf @""]
    (with-dyns [:out buf] ((gate :skip) "some-suite"))
    (string buf)))
(assert (= "some-suite: SKIPPED (set VOID_TEST_TEST_SERVICE to a test:// url)\n" announced)
        "the skip line names the suite, the variable and what to set it to")
# captured like the line above: a real SKIPPED line on this suite's
# stdout would be a hit for the CI grep the gate prints it for
(def quiet
  (let [buf @""]
    (with-dyns [:out buf] ((gate :skip) "quiet"))))
(assert (nil? quiet) "and skip returns nil, so it can stand in an if")

(print "test-test: all assertions passed")
