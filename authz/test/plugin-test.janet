(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/authz :as authz)
(import void/authz/policy :as policy)
(import void/authz/context :as context)
(import void/authz/decide :as decide)
(import void/authz/rbac :as rbac)

(log/set-level! "void" :error)

(def plugins ["void/authz/init"])

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "void/authz composes on the kernel alone — no HTTP, and no void/auth either")
(assert (index-of :authz/registry (report :components)))
(each point [:void.authz/provider :void.authz/policy]
  (assert (get-in report [:extensions point])))

(each [slice reason]
  [[{:authz {:default :maybe}} "a posture that is neither :allow nor :deny"]
   [{:authz {:log :verbose}} "a log mode that does not exist"]
   [{:authz {:roles [:admin]}} "a role table that is not a table"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:authz {:roles {:admin [:*] :support [:orders/read]}
                                                   :log :none}})}))

(def value (get-in boot [:system :instances :authz/registry]))
(assert value "the registry started")
(assert (index-of :public (value :policies)) "with the built-in policies registered")
(assert (index-of :authenticated (value :policies)))
(assert (= :allow (value :default)) "and :allow as the default posture")
(assert (= [:*] (tuple ;(get-in value [:roles :admin])))
        "the role table reached the registry")
(assert (= [:orders/read] (tuple ;(get rbac/roles :support)))
        "and rbac reads it")
(assert (= :none decide/log-mode) "[:authz :log] reached the decision log")

(assert (authz/can? :public {}))
(assert (not (authz/can? :authenticated {})))
(assert (authz/can? :authenticated {:subject {:subject "user:1"}}))
(assert (authz/permitted? (authz/make-context {:subject {:subject "u" :claims {:role :support}}})
                          :orders/read))

(def health (first (filter |(= :authz/registry ($ :name))
                           (plugin/extension boot :void.core/health))))
(assert (= :up (((health :fn)) :status)))

# the CLI renders the registry
(def printed @"")
(def cli (plugin/extension boot :void.core/cli))
(defn- run-cli [name & args]
  (buffer/clear printed)
  (def cmd (first (filter |(= name ($ :name)) cli)))
  (assert cmd (string/format "%q is a command" name))
  (with-dyns [*out* printed] ((cmd :fn) value ;args))
  (string printed))

(def listed (run-cli :authz/policies))
(assert (string/find "public" listed))
(assert (string/find "authenticated" listed))

(authz/defpolicy :orders/read "own brand" [ctx]
  (or (= (authz/attr ctx :subject/brand-id) 3) "brand mismatch"))

(def explained (run-cli :authz/explain "orders/read" "user:7" "brand-id=3"))
(assert (string/find "user:7" explained))
(assert (string/find "allow" explained))
(def denied (run-cli :authz/explain "orders/read" "user:7" "brand-id=9"))
(assert (string/find "DENY" denied))
(assert (string/find "brand mismatch" denied)
        "`void authz explain` is the one place the reason is meant to be read")

(plugin/shutdown! boot 3)

# -- contributions -------------------------------------------------------

(def app
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/authz ">=0.0.1"}
    :contributes
    {:void.authz/policy [{:name :plugin/allowed :doc "shipped by a plugin"
                          :fn (fn [_] true)}]
     :void.authz/provider [{:name :test/brand :for :subject :keys [:subject/brand-id]
                            :fn (fn [_] {:brand-id 42})}]}))

(def boot2 (plugin/start! {:plugins [;plugins app] :profile :test :config (config {})}))
(assert (index-of :plugin/allowed (authz/policies))
        "a policy a plugin ships is registered like any other")
(assert (index-of :test/brand (authz/providers)))
(assert (= 42 (authz/attr (authz/make-context {:subject {:subject "u:1"}}) :subject/brand-id))
        "and its provider answers")
(plugin/shutdown! boot2 3)

(def dup
  (plugin/manifest 'test/dup
    :version "0.1.0"
    :requires {:void/authz ">=0.0.1"}
    :contributes {:void.authz/provider [{:name :p :for :subject :fn (fn [_] {})}
                                        {:name :p :for :env :fn (fn [_] {})}]}))
(def [ok] (protect (plugin/dry-run {:plugins [;plugins dup] :profile :test :config (config {})})))
(assert (not ok) "two providers under one name is a boot error")

(def bad-provider
  (plugin/manifest 'test/bad
    :version "0.1.0"
    :requires {:void/authz ">=0.0.1"}
    :contributes {:void.authz/provider [{:name :p :for :whatever :fn (fn [_] {})}]}))
(def [ok2] (protect (plugin/dry-run {:plugins [;plugins bad-provider] :profile :test :config (config {})})))
(assert (not ok2) "and so is a provider for a group that does not exist")

(print "plugin-test ok")
