(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/security :as security)
(import void/security/secret :as secret)
(require "void/crypto/init")

(log/set-level! "void" :error)

(def plugins ["void/http/init" "void/crypto/init" "void/security/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}
                :http {:port 0 :access-log false}
                :security {:signing-key (string/repeat "k" 32)}}
               extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok))
(assert (= 2 (get-in report [:extensions :void.http/edge :contributions])))

(def [no-crypto] (protect (plugin/dry-run {:plugins ["void/http/init" "void/security/init"]
                                           :profile :test :config (config {})})))
(assert (not no-crypto)
        "void/security does not compose without void/crypto: every token it issues is signed")

(each [slice reason]
  [[{:security {:csp {:policy {:scripts-src [:self]}}}} "a misspelled CSP directive"]
   [{:security {:cors {:credentials true :origins ["*"]}}} "* with credentials"]
   [{:security {:rate {:enabled true :store :postgres}}} "a store that does not exist"]
   [{:security {:trusted-proxies "10.0.0.0/8"}} "a proxy list that is not a list"]]
  (def [ok] (protect (test/start! {:plugins plugins :only [:http/kernel :crypto/lib]
                                   :profile :test :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- the signing key -----------------------------------------------------

(def [ok err] (protect (test/start! {:plugins plugins :only [:http/kernel :crypto/lib]
                                     :profile :prod
                                     :config {:env @{} :cli {:log {:level :error}
                                                             :http {:port 0 :access-log false}}}})))
(assert (not ok) "in production a missing signing key stops the boot")
(assert (string/find "signing-key" (string err)))

(def boot (test/start! {:plugins plugins :only [:http/kernel :crypto/lib]
                        :profile :test :config (config {})}))

(defer (test/stop! boot)
  (assert (= 1 (length secret/keys)) "the configured key is installed")

  (def health (first (filter |(= :security/config ($ :name))
                             (plugin/extension boot :void.core/health))))
  (def h ((health :fn)))
  (assert (= :up (h :status)))
  (assert (h :csrf))
  (assert (not (h :cors)) "CORS is off until an allowlist exists")
  (assert (not (h :rate)) "and so is the limiter — both are numbers only the deployment knows")

  (def printed @"")
  (with-dyns [*out* printed] (security/print-status))
  (def text (string printed))
  (each part ["x-content-type-options" "nosniff" "content-security-policy"
              "csrf     on" "cors     off" "none trusted"]
    (assert (string/find part text) part)))

# -- the rate limiter needs a store it can reach -------------------------

(def [ok2 err2]
  (protect (test/start! {:plugins plugins :only [:http/kernel :crypto/lib]
                         :profile :test
                         :config (config {:security {:signing-key (string/repeat "k" 32)
                                                     :rate {:enabled true :store :cache}}})})))
(assert (not ok2) "asking for the cache store without void/cache in the composition stops the boot")
(assert (string/find "void/cache" (string err2)) "and says what to add")

(def with-memory (test/start! {:plugins plugins :only [:http/kernel :crypto/lib]
                               :profile :test
                               :config (config {:security {:signing-key (string/repeat "k" 32)
                                                           :rate {:enabled true}}})}))
(test/stop! with-memory)

(print "plugin-test ok")
