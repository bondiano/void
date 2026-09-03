(import ../test-support/paths)
(import void/crypto/lib :as lib)

# -- before anything is open ---------------------------------------------

(assert (not (lib/available?)) "nothing is open until load! runs")
(assert (empty? (lib/algorithms)) "and a library that is not open provides nothing")
(assert (nil? (lib/version)) "no version either")

(def [ok err] (protect (lib/ensure!)))
(assert (not ok) "ensure! before load! is an error")
(assert (string/find "libcrypto" (string err)))
(each c (lib/candidates)
  (assert (string/find c (string err))
          "and the error says where it looked — a path missing from the message is a support ticket"))

# -- the macOS trap ------------------------------------------------------
#
# `(ffi/native "libcrypto.dylib")` and "/usr/lib/libcrypto.dylib" abort
# the process on macOS: the system LibreSSL shim calls abort(), protect
# does not catch it, and `void routes` would die on any Mac. This
# assertion exists so that "unify the candidate lists" fails here rather
# than in somebody's terminal.

(when (= :macos (os/which))
  (each c lib/default-candidates
    (assert (string/has-prefix? "/" c)
            (string/format "macOS candidate %q is a bare name — loading libcrypto by soname aborts the process" c))
    (assert (not (string/has-prefix? "/usr/lib/" c))
            (string/format "macOS candidate %q is the system LibreSSL shim, which aborts the process" c))))

(when (= :linux (os/which))
  (assert (index-of "libcrypto.so.3" lib/default-candidates)
          "on Linux the soname is the right thing to ask the loader for"))

# -- the search order ----------------------------------------------------

(assert (= ["/somewhere/libcrypto.so"] (lib/candidates "/somewhere/libcrypto.so"))
        "a configured path is tried alone — no silent fallback to another library")
(assert (deep= lib/default-candidates (lib/candidates))
        "without one, the platform's list")

# -- opening it ----------------------------------------------------------

(def path (lib/load!))
(assert (lib/available?))
(assert (= path lib/library-path))
(assert (= path (lib/load!)) "load! is idempotent for the same library")
(assert (= path (lib/ensure!)) "and ensure! hands back the path")

(def [major minor patch] (lib/version))
(assert (>= major 1) "a version came back as three plain numbers, not as u64 abstracts")
(assert (number? minor))
(assert (number? patch))
(assert (string/find "SSL" (lib/version-text)))

# -- what this library can do --------------------------------------------

(def algos (lib/algorithms))
(each required [:sha256 :sha512 :hmac :scrypt :pbkdf2 :rs256 :es256]
  (assert (algos required)
          (string/format "%q is in every libcrypto void supports" required)))
(assert (boolean? (algos :argon2id))
        "argon2id is reported, never assumed: it needs OpenSSL 3.2 and an LTS distribution may ship 3.0")
(assert (= (algos :argon2id) (>= (+ (* 100 major) minor) 302))
        (string/format
          (string "argon2id reported as %q by OpenSSL %d.%d — the EVP_KDF symbols arrived "
                  "in 3.0 and the ARGON2ID implementation in 3.2, so the answer has to come "
                  "from fetching the KDF, not from the symbol table")
          (algos :argon2id) major minor))
(when (not (empty? lib/missing))
  (assert (not (algos :argon2id))
          "a library without the EVP_KDF symbols cannot derive with argon2id either"))

(each sym lib/missing
  (assert (string/has-prefix? "EVP_KDF" sym)
          (string/format "only the argon2id symbols are optional, but %s is missing" sym)))

(print "lib-test ok")
