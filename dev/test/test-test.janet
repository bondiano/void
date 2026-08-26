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

(print "test-test: all assertions passed")
