(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/auth :as auth)
(import void/auth/state :as state)
(import void/auth/hash :as hash)
(import void/auth/strategy :as strategy)
(import void/crypto/kdf :as kdf)

(log/set-level! "void" :error)

(def plugins ["void/crypto/init" "void/auth/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}
                :crypto {:kdf {:in-thread false}}
                :auth {:scrypt {:ln 10}}}
               extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "void/auth composes on core + void/crypto — no HTTP kernel anywhere in it")
(each key [:auth/registry :auth/memory-users :auth/memory-tokens :auth/memory-challenges]
  (assert (index-of key (report :components)) (string/format "%q is a component" key)))
(each point [:void.auth/strategy :void.auth/hasher :void.auth/deliver]
  (assert (get-in report [:extensions point]) (string/format "%q is owned by this plugin" point)))

(def without-crypto (protect (plugin/dry-run {:plugins ["void/auth/init"] :profile :test
                                              :config (config {})})))
(assert (not (first without-crypto))
        "and without void/crypto it does not compose at all — every primitive comes from there (ADR-0022)")

(each [slice reason]
  [[{:auth {:hasher "scrypt"}} "a hasher that is not a keyword"]
   [{:auth {:strategies :session}} "a strategy list that is not a list"]
   [{:auth {:users "none"}} "a user table that is not a table"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:auth {:scrypt {:ln 10}
                                                  :users {"user:1" {:email "a@b.c"}}}})}))

(def value (get-in boot [:system :instances :auth/registry]))
(assert value "the registry started")
(assert (= value (state/active)) "and the module surface reaches it")
(assert (= :memory (get-in value [:users :name])))
(assert (= :memory (get-in value [:tokens :name])))
(assert (= :memory (get-in value [:challenges :name])))
(assert (deep= [:password] (tuple ;(auth/strategies)))
        "the built-in password strategy is registered; the request strategies live in void/auth-http")
(assert (= "user:1" (((auth/user-store) :subject)
                     (((auth/user-store) :find) {:by :email :value "a@b.c"})))
        "and [:auth :users] seeded the memory store")

(assert (= :scrypt (hash/active-hasher)))
(assert (= 10 (get-in (state/settings) [:scrypt :ln])) "the configured cost reached the hasher")
(assert (not kdf/in-thread) "and [:crypto :kdf :in-thread] reached void/crypto")

(def health (first (filter |(= :auth/registry ($ :name))
                           (plugin/extension boot :void.core/health))))
(assert (= :up (((health :fn)) :status)))

# the CLI commands render what the composition holds
(def printed @"")
(def cli (plugin/extension boot :void.core/cli))
(defn- run-cli [name & args]
  (buffer/clear printed)
  (def cmd (first (filter |(= name ($ :name)) cli)))
  (assert cmd (string/format "%q is a command" name))
  (with-dyns [*out* printed]
    ((cmd :fn) (get-in boot [:system :instances :auth/registry]) ;args))
  (string printed))

(def hashed (string/trim (run-cli :auth/hash "hunter2")))
(assert (string/has-prefix? "$scrypt$ln=10," hashed) hashed)
(assert (deep= [true false] (auth/verify-password "hunter2" hashed))
        "`void auth hash` prints exactly what goes in [:auth :users]")

(def listed (run-cli :auth/strategies))
(assert (string/find "password" listed))
(assert (string/find "login" listed))

(def minted (run-cli :auth/token "service:ci" "deploys"))
(assert (string/has-prefix? "vt_" (string/trim minted)) minted)
(assert (= "service:ci" ((auth/verify-token (auth/token-store) (string/trim minted)) :subject))
        "and the token it printed works")

(plugin/shutdown! boot 3)
(assert (nil? (state/active)) "stopping takes the resolved value with it")
(assert (= :down (((health :fn)) :status))
        "and the health check answers even when there is nothing to report")

# -- a hasher that is not there ------------------------------------------

(def [ok err] (protect (plugin/start! {:plugins plugins :profile :test
                                       :config (config {:auth {:hasher :bcrypt}})})))
(assert (not ok) "[:auth :hasher] naming something unregistered stops the boot")
(assert (string/find "bcrypt" (string err)))

# -- a strategy contributed by an application ----------------------------

(def app
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/auth ">=0.0.1"}
    :contributes
    {:void.auth/strategy [{:name :api-key
                           :authenticate (fn [req] nil)
                           :priority 5}]
     :void.auth/deliver [{:name :test/deliver :fn (fn [challenge] nil)}]}))

(def boot2 (plugin/start! {:plugins [;plugins app] :profile :test :config (config {})}))
(assert (index-of :api-key (auth/strategies))
        "a contributed strategy is registered at start, exactly like a built-in one")
(assert (deep= [:api-key] (tuple ;(map |($ :name) (strategy/request-strategies)))))
(assert (= 1 (length (get-in boot2 [:extensions :void.auth/deliver :resolved])))
        "and the delivery point carries what void/mail will contribute in 3.5")
(plugin/shutdown! boot2 3)

(def dup
  (plugin/manifest 'test/dup
    :version "0.1.0"
    :requires {:void/auth ">=0.0.1"}
    :contributes {:void.auth/strategy [{:name :dup :verify (fn [_])}
                                       {:name :dup :verify (fn [_])}]}))
(def [ok2] (protect (plugin/dry-run {:plugins [;plugins dup] :profile :test :config (config {})})))
(assert (not ok2) "two strategies under one name is a boot error, not a silent last-one-wins")

(def broken
  (plugin/manifest 'test/broken
    :version "0.1.0"
    :requires {:void/auth ">=0.0.1"}
    :contributes {:void.auth/strategy [{:name :useless}]}))
(def [ok3] (protect (plugin/dry-run {:plugins [;plugins broken] :profile :test :config (config {})})))
(assert (not ok3) "a strategy that can neither read a request nor verify credentials fails validation")

(print "plugin-test ok")
