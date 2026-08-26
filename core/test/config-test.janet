(import ../void/core/config :as config)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

(def fixtures "test-support/fixtures/config")

# -- layer precedence: defaults <- files <- env <- cli ------------------

(def cfg
  (config/load
    {:defaults [{:plugin :void/db :key :database
                 :defaults {:host "default-host" :port 1111 :pool-size 5}}]
     :dir fixtures
     :profile :dev
     :env {"TEST_DB_PASSWORD" "s3cret-value"
           "VOID_DATABASE__HOST" "env-host"
           "VOID_DATABASE__POOL_SIZE" "10"
           "VOID_PROFILE" "prod"
           "UNRELATED" "x"}
     :cli ["--database.host=cli-host"]}))

(assert (= (config/value cfg :database :host) "cli-host")
        "CLI override wins over env, file and defaults")
(assert (= (config/value cfg :database :port) 5433)
        "profile file wins over default file and plugin defaults")
(assert (= (config/value cfg :database :pool-size) 10)
        "env var wins over defaults and is coerced to a number")
(assert (= (config/value cfg :app :name) "demo")
        "default.jdn file layer is applied")
(assert (= (config/value cfg :app :profile-seen) :dev)
        "janet config file sees (dyn :void/profile)")
(assert (nil? (config/value cfg :profile))
        "VOID_PROFILE and non-prefixed env vars are not config values")

# -- provenance / explain -----------------------------------------------

(def e (config/explain cfg :database :host))
(assert (= (get-in e [:source :layer]) :cli) "winning source is the CLI layer")
(assert (= (length (e :history)) 4)
        "history keeps all four layers that set :database :host")
(assert (= (freeze (map |(get $ :layer) (e :history))) [:defaults :file :env :cli])
        "shadowed layers are recorded oldest-first")

(def s (config/explain-str cfg :database :pool-size))
(assert (string/find "env var VOID_DATABASE__POOL_SIZE" s)
        "explain-str names the env var")
(assert (string/find "defaults of plugin :void/db" s)
        "explain-str names the shadowed plugin defaults")

(def sub (config/explain cfg :database))
(assert (nil? (get sub :source)) "subtree path has no single source")
(assert (> (length (sub :children)) 2) "subtree explain lists leaf sources")

(assert (string/find "not set" (config/explain-str cfg :nope :nothing))
        "explain-str reports unset paths")

# -- profiles ------------------------------------------------------------

(def prod-cfg
  (config/load {:dir fixtures :profile :prod
                :env {"TEST_DB_PASSWORD" "p"}}))
(assert (= (config/value prod-cfg :database :host) "db.prod.internal")
        "prod profile picks prod.jdn")
(assert (= (config/value prod-cfg :database :port) 5432)
        "prod profile does not see dev.janet")

(def staging-cfg
  (config/load {:dir fixtures :profile :staging
                :env {"TEST_DB_PASSWORD" "p"}}))
(assert (= (staging-cfg :profile) :staging)
        "arbitrary profiles are allowed; missing profile file is fine")

# -- secrets -------------------------------------------------------------

(def password (config/value cfg :database :password))
(assert (config/secret? password) "secret spec is resolved into a box")
(assert (= (config/reveal password) "s3cret-value") "reveal returns the value")
(assert (nil? (string/find "s3cret-value" (string/format "%q" password)))
        "printing the box does not leak the value")
(assert (nil? (string/find "s3cret-value" (string/format "%q" (cfg :values))))
        "printing the whole config tree does not leak the value")
(expect-error "reveal of a non-secret" "not a secret box"
  |(config/reveal @{:secret "X"}))

(def file-cfg
  (config/load {:dir "test-support/fixtures/nope"
                :env {}
                :defaults {:app {:token {:secret "TOKEN"
                                         :file (string fixtures "/secret.txt")}}}}))
(assert (= (config/reveal (config/value file-cfg :app :token)) "file-secret-value")
        "secrets resolve from files, trimmed")

(def custom-cfg
  (config/load {:dir "test-support/fixtures/nope"
                :env {}
                :defaults {:app {:token {:secret "VAULT_KEY"}}}
                :secret-sources [(fn [spec] (when (= (spec :secret) "VAULT_KEY")
                                              "from-vault"))]}))
(assert (= (config/reveal (config/value custom-cfg :app :token)) "from-vault")
        "custom secret sources are tried first")

# -- batch errors on load ------------------------------------------------

(def batch-err
  (expect-error "missing secrets are batched" "config errors"
    |(config/load {:dir "test-support/fixtures/nope"
                   :env {}
                   :files [(string fixtures "/missing.jdn")]
                   :defaults {:a {:s1 {:secret "NO_SUCH_ONE"}}
                              :b {:s2 {:secret "NO_SUCH_TWO"}}}})))
(assert (string/find "NO_SUCH_ONE" batch-err) "first missing secret reported")
(assert (string/find "NO_SUCH_TWO" batch-err) "second missing secret reported")
(assert (string/find "missing.jdn" batch-err) "missing explicit file reported too")

(expect-error "unknown load option" "unknown option"
  |(config/load {:profil :dev}))

# -- CLI override forms --------------------------------------------------

(def cli-cfg
  (config/load {:dir "test-support/fixtures/nope"
                :env {}
                :cli {:app {:debug true}}}))
(assert (= (config/value cli-cfg :app :debug) true) "dict-form CLI overrides work")

(expect-error "malformed CLI override" "path.to.key=value"
  |(config/load {:dir "test-support/fixtures/nope" :env {} :cli ["oops"]}))

# -- batch schema validation --------------------------------------------

(def specs
  [{:key :database :plugin :void/db
    :schema (fn [c] (number? (get c :port)))}
   {:key :app :plugin :void/app
    :schema (fn [c] (error "boom"))}
   {:key :database :plugin :void/other
    :schema (fn [c] true)}])

(def errors (config/validate cfg specs))
(assert (= (length errors) 1) "only the throwing schema fails on valid config")
(assert (string/find "boom" (first errors)) "schema error text is preserved")

(def bad-cfg (config/load {:dir "test-support/fixtures/nope" :env {}
                           :defaults {:database {:port "not-a-number"}}}))
(def bad-errors (config/validate bad-cfg specs))
(assert (= (length bad-errors) 2)
        "validation collects all failures in one batch, not first-fail")
(assert (string/find ":void/db" (string/join bad-errors "; "))
        "errors name the plugin that declared the schema")
(expect-error "validate! throws the batch" "validation failed"
  |(config/validate! bad-cfg specs))
(assert (= cfg (config/validate! cfg [{:key :database :schema |(number? (get $ :port))}]))
        "validate! returns the config when valid")

(print "void/core/config tests OK")
