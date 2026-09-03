(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/crypto/lib :as lib)
(import void/crypto/kdf :as kdf)

(log/set-level! "void.crypto" :error)

(def plugins ["void/crypto/init"])

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own — core only, no http anywhere in it")
(assert (index-of :crypto/lib (report :components)))
(assert (not (lib/available?))
        "and a dry run opens nothing: validating a composition in CI must not need OpenSSL on the runner")

(each [slice reason]
  [[{:crypto {:libcrypto :nope}} "a library path that is not a string"]
   [{:crypto {:require :argon2id}} "a :require that is not a list"]
   [{:crypto {:kdf {:in-thread "yes"}}} "an :in-thread that is not a boolean"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test
                                      :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- a library that is not there -----------------------------------------

(def [ok err]
  (protect (plugin/start! {:plugins plugins :profile :test
                           :config (config {:crypto {:libcrypto "/nowhere/libcrypto.so"}})})))
(assert (not ok) "a configured path that does not exist stops the boot")
(assert (string/find "/nowhere/libcrypto.so" (string err))
        "and the error names the path that was tried, not just the failure")
(assert (not (lib/available?)) "nothing got opened")

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:crypto {:kdf {:in-thread false}}})}))

(def inst (get-in boot [:system :instances :crypto/lib]))
(assert inst "the library component started")
(assert (lib/available?) "and the library is open for every module in the package")
(assert (= (inst :path) lib/library-path))
(assert (get-in inst [:algorithms :sha256]))
(assert (not kdf/in-thread)
        "[:crypto :kdf :in-thread] reached the module — this is the switch tests and CLI scripts use")

# the surface works through the one import an application makes
(assert (= 32 (length (crypto/sha256 "abc"))))
(assert (= 43 (length (crypto/token))))
(assert (crypto/equal? (crypto/hmac-sha256 "k" "m") (crypto/hmac-sha256 "k" "m")))

(def health (first (filter |(= :crypto/library ($ :name))
                           (plugin/extension boot :void.core/health))))
(def h ((health :fn)))
(assert (= :up (h :status)))
(assert (string/find "SSL" (h :version)))
(assert (index-of :sha256 (h :algorithms)))

# the CLI command renders what the component holds
(def printed @"")
(with-dyns [*out* printed] (crypto/print-info inst))
(def text (string printed))
(assert (string/find "library" text))
(assert (string/find "sha256" text))
(assert (string/find "on the event loop" text)
        "and it says where derivation runs, because that is a decision with a cost")

(plugin/shutdown! boot 3)

# -- an algorithm the application cannot live without --------------------

(def algos (lib/algorithms))

(def [ok2 err2]
  (protect (plugin/start! {:plugins plugins :profile :test
                           :config (config {:crypto {:require [:blake3]}})})))
(assert (not ok2) "[:crypto :require] refuses to start without the algorithm it names")
(assert (string/find "blake3" (string err2)))
(assert (string/find "OpenSSL 3.2" (string err2))
        "and the message points at the one that is actually version-dependent")

(def boot2 (plugin/start! {:plugins plugins :profile :test
                           :config (config {:crypto {:require [:scrypt :sha256]}})}))
(assert boot2 "algorithms every libcrypto has do not stop anything")
(plugin/shutdown! boot2 3)

(if (algos :argon2id)
  (let [b (plugin/start! {:plugins plugins :profile :test
                          :config (config {:crypto {:require [:argon2id]}})})]
    (assert b "this library has argon2id, so requiring it starts")
    (plugin/shutdown! b 3))
  (let [[ok3 err3] (protect (plugin/start! {:plugins plugins :profile :test
                                            :config (config {:crypto {:require [:argon2id]}})}))]
    (assert (not ok3)
            "this library has no argon2id, and an application that requires it must not start")
    (assert (string/find "argon2id" (string err3)))
    (printf "SKIP argon2id: %s" (lib/version-text))))

(print "plugin-test ok")
