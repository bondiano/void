### void/crypto — every cryptographic primitive void has, from one system
### library.
###
### Janet 1.41 ships `os/cryptorand` and nothing else: no SHA-2, no
### HMAC, no key derivation, no signatures. Wave 3 needs all of them,
### in three different packages — passwords and API tokens in
### `void/auth`, the CSRF token in `void/security`, JWS verification in
### both — so they live here, once, and come from libcrypto rather
### than from an implementation of our own;
### the short version is that a web framework has no business writing
### SHA-2, on Janet or in C.
###
### What an application composes:
###
###     (void/run! {:plugins [:void/crypto :void/auth :void/security ...]})
###     # config/prod.janet
###     {:crypto {:require [:argon2id]}}
###
### The plugin owns exactly one thing at runtime: the open library. It
### opens it at `:start` — so a missing OpenSSL is a boot error naming
### every path it tried, not a nil call on the first login — reports
### what that particular library can do (`void crypto info`), and can
### be told to refuse to start without an algorithm the application
### depends on (`[:crypto :require]`). That last one matters more than
### it looks: argon2id needs OpenSSL 3.2, an LTS distribution may ship
### 3.0, and "we thought we were on argon2id" is a thing to discover at
### deploy time rather than a year later.
###
### Everything else in the package is plain modules — `crypto/sha256`,
### `crypto/hmac-sha256`, `crypto/scrypt`, `crypto/token`,
### `crypto/equal?`, `crypto/sign` — re-exported below, so a caller
### imports one name. They work without the plugin as long as
### `(crypto/load!)` has run, which is what tests and one-shot scripts
### do.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./lib :as lib)
(import ./digest :as digest)
(import ./encode :as encode)
(import ./kdf :as kdf)
(import ./random :as random)
(import ./sign :as sign-mod)
(import ./ct :as ct)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.crypto")

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:crypto] config slice."
  {:libcrypto [:optional :string]
   :kdf [:optional {:in-thread [:optional :boolean]}]
   :require [:optional [:vector :keyword]]})

(def defaults
  ``Defaults of the [:crypto] slice.

  `:libcrypto` unset means the platform's candidate list (see
  ./lib) — an explicit path is for a machine where OpenSSL lives
  somewhere unusual, and `VOID_LIBCRYPTO` overrides both.

  `[:kdf :in-thread] true` keeps key derivation off the event loop.
  scrypt at the default cost is ~25 ms of uninterruptible CPU, and on
  a single-threaded loop that is 25 ms during which the worker answers
  nobody — measured, not assumed. Set it false in tests and one-shot
  scripts, where a worker thread per hash is the larger cost.

  `:require` is empty: void does not decide for an application which
  algorithms it may not live without.``
  {:libcrypto nil
   :kdf {:in-thread true}
   :require []})

(defn- slice [cfg]
  (def c (merge defaults (or cfg {})))
  # the nested table has to be merged on its own — `merge` is shallow,
  # and a config that sets only [:kdf :in-thread] would otherwise drop
  # every other key of the slice
  (put c :kdf (merge (defaults :kdf) (get cfg :kdf {})))
  c)

# -- public surface (re-exports) -----------------------------------------

(def load! "See lib/load! — open libcrypto and install the bindings." lib/load!)
(def available? "See lib/available? — is a library open?" lib/available?)
(def library-path "See lib/library-path — the path that was opened." lib/library-path)
(def candidates "See lib/candidates — where the library is looked for." lib/candidates)
(def version "See lib/version — [major minor patch] of the open library." lib/version)
(def version-text "See lib/version-text — what the library calls itself." lib/version-text)
(def algorithms "See lib/algorithms — what this particular library can do." lib/algorithms)

(def digest-of "See digest/digest — hash bytes with a named algorithm." digest/digest)
(def sha256 "See digest/sha256 — raw bytes, never hex." digest/sha256)
(def sha384 "See digest/sha384." digest/sha384)
(def sha512 "See digest/sha512." digest/sha512)
(def hmac "See digest/hmac." digest/hmac)
(def hmac-sha256 "See digest/hmac-sha256 — what signs a CSRF token and an HS256 JWS." digest/hmac-sha256)

(def scrypt "See kdf/scrypt — the default password KDF." kdf/scrypt)
(def argon2id "See kdf/argon2id — OpenSSL 3.2+ only, see `algorithms`." kdf/argon2id)
(def pbkdf2 "See kdf/pbkdf2 — for hashes that arrive from another stack." kdf/pbkdf2)
(def derive "See kdf/derive — one derivation from a data spec." kdf/derive)
(def kdf-defaults "See kdf/defaults — cost parameters and the argument for them." kdf/defaults)

(def random-bytes "See random/bytes — n random bytes from the OS." random/bytes)
(def token "See random/token — a URL-safe random token." random/token)
(def hex-token "See random/hex-token." random/hex-token)
(def digits "See random/digits — a numeric one-time code without modulo bias." random/digits)

(def base64url "See encode/base64url — RFC 4648 §5, no padding." encode/base64url)
(def base64url-decode "See encode/base64url-decode." encode/base64url-decode)
(def base64 "See encode/base64 — standard alphabet, no padding (PHC)." encode/base64)
(def base64-decode "See encode/base64-decode." encode/base64-decode)
(def hex "See encode/hex." encode/hex)
(def unhex "See encode/unhex." encode/unhex)

(def equal? "See ct/equal? — comparison that does not leak by timing." ct/equal?)

(def public-key "See sign/public-key — open a PEM public key." sign-mod/public-key)
(def private-key "See sign/private-key." sign-mod/private-key)
(def free-key "See sign/free-key." sign-mod/free-key)
(def sign "See sign/sign — a JWS-form signature." sign-mod/sign)
(def verify "See sign/verify." sign-mod/verify)
(def signature-algorithms "See sign/algorithms — RS*/ES* and their digests." sign-mod/algorithms)

# -- the component -------------------------------------------------------

(defn- available-list [algos]
  (sorted (seq [[k v] :pairs algos :when v] k)))

(def lib-component
  (system/component :crypto/lib
    :doc "The open libcrypto: found at :start from [:crypto :libcrypto]
    or the platform's candidate list, with every binding this package
    uses installed. Refuses to start when an algorithm named in
    [:crypto :require] is missing from the library that was found —
    argon2id needs OpenSSL 3.2 and an LTS distribution may ship 3.0."
    :provides [:void/crypto]
    :config {:key :crypto :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def path (lib/load! (cfg :libcrypto)))
      (set kdf/in-thread (get-in cfg [:kdf :in-thread] true))
      (def algos (lib/algorithms))
      (def wanted (get cfg :require []))
      (def absent (filter |(not (get algos $)) wanted))
      (unless (empty? absent)
        (errorf (string "[:crypto :require] names %s, which %s (%s) does not "
                        "provide. argon2id needs OpenSSL 3.2 or newer; this "
                        "library has %s")
                (string/join (map |(string/format "%q" $) absent) " ")
                path (or (lib/version-text) "unknown version")
                (string/join (map string (available-list algos)) " ")))
      (log/info "libcrypto ready" :ns log-ns
                :path path
                :version (lib/version-text)
                :algorithms (available-list algos)
                :kdf-in-thread kdf/in-thread)
      (unless (get algos :argon2id)
        (log/debug "argon2id is not available (OpenSSL 3.2+); :scrypt is the default hasher"
                   :ns log-ns :version (lib/version-text)))
      {:path path
       :version (lib/version)
       :version-text (lib/version-text)
       :algorithms algos
       :kdf-in-thread kdf/in-thread})
    :health
    (fn health [inst]
      {:status :up
       :library (inst :path)
       :version (inst :version-text)
       :algorithms (available-list (inst :algorithms))})))

# -- interface, health, CLI ----------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/crypto
   :doc "The open cryptographic library: which one, which version and which algorithms it provides. Depend on the interface rather than on the component key to let a test stand something else in its place."
   :methods {:path "the library this process opened"
             :version "[major minor patch]"
             :algorithms "algorithm -> available?"}})

(plugin/contribute! :void.core/health
  {:name :crypto/library
   :fn (fn crypto-health []
         (if (lib/available?)
           {:status :up
            :library lib/library-path
            :version (lib/version-text)
            :algorithms (available-list (lib/algorithms))}
           {:status :down :reason "no libcrypto is open"}))})

(defn print-info
  "Print what this process's libcrypto can do — the body of
  `void crypto info`."
  [inst]
  (printf "library    %s" (inst :path))
  (printf "version    %s" (or (inst :version-text) "—"))
  (printf "kdf        %s"
          (if (inst :kdf-in-thread)
            "on a worker thread"
            "on the event loop — [:crypto :kdf :in-thread] is false"))
  (print "algorithms")
  (each [k v] (sorted (pairs (inst :algorithms)))
    (printf "  %-10s %s" (string k)
            (if v "yes" "no   (needs OpenSSL 3.2)"))))

(plugin/contribute! :void.core/cli
  {:name :crypto/info
   :read-only? true
   :doc "Show which libcrypto is open and what it provides: void crypto info"
   :needs [:crypto/lib]
   # :needs instances come first, then the string arguments
   :fn (fn cli-info [inst & args]
         (unless (empty? args)
           (errorf "void crypto info takes no arguments (got %q)"
                   (string/join args " ")))
         (print-info inst))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/crypto
  :doc "Cryptographic primitives from the system libcrypto through ffi: SHA-2 and HMAC, scrypt/argon2id/PBKDF2 derived off the event loop, RS256/ES256 signatures, constant-time comparison and OS randomness. The library is opened at :start, so a missing OpenSSL is a boot error rather than a surprise on the first login."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :crypto
  :config-schema Config
  :config-defaults defaults
  :components [lib-component])
