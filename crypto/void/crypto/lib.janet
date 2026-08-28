### void/crypto/lib — the libcrypto surface void uses, and nothing more
### (ADR-0022, SPEC.md §5.14, §5.16).
###
### Everything here is `ffi/`, for the reason ADR-0022 spells out: a web
### framework has no business implementing SHA-2, HMAC or a memory-hard
### KDF, on Janet or in C. The primitives come from the library the
### operating system already ships and somebody else audits.
###
### The bindings are `var`s installed by `load!` rather than
### `ffi/defbind` definitions, and that is the same decision
### `void/db-postgres/libpq` made (ADR-0011): the library path is
### configuration ([:crypto :libcrypto]), not a compile-time constant,
### and a plugin that merely gets *loaded* — `plugin/dry-run` in CI,
### `void routes` on a laptop — must not explode on import. Until
### `load!` runs, every binding is nil and `available?` says so.
###
### **The macOS trap, which is the reason this list is written out by
### platform.** On macOS 15 with Janet 1.41, both
###
###     (ffi/native "libcrypto.dylib")
###     (ffi/native "/usr/lib/libcrypto.dylib")
###
### *kill the process*: the system LibreSSL shim prints `WARNING: janet
### is loading libcrypto in an unsafe way` and calls abort(). It is not
### an error value, `protect` does not catch it, and the ordinary
### try-the-candidates loop that is harmless on Linux would take down
### `void routes` on any Mac. So the macOS list contains **explicit
### paths only** — never the bare name, never /usr/lib — and a test
### pins that, because "unify the candidate lists" is an obvious and
### fatal cleanup.
###
### Two other facts are load-bearing:
###
###   * `EVP_KDF_*` (argon2id) is optional. OpenSSL grew the ARGON2ID
###     KDF in 3.2; Ubuntu 24.04 LTS ships 3.0. The symbols are marked
###     :optional, `algorithms` reports what is actually there, and the
###     default hasher is scrypt, which has been present since 1.1.
###   * A `char *` return that can be NULL must be declared :ptr, not
###     :string — janet builds a string straight off the pointer, and
###     off NULL that is a segfault rather than an error. Only
###     `OpenSSL_version`, documented non-NULL, is :string here.

(def path-env
  "Environment variable that overrides the search — the escape hatch
  for a machine where libcrypto lives somewhere unusual."
  "VOID_LIBCRYPTO")

(def default-candidates
  ``Where libcrypto is looked for when nothing is configured, in
  order.

  On Linux a bare soname goes through the dynamic loader's own search
  path, which is what every distribution sets up. On **macOS the bare
  name is forbidden** (see the module docstring: it aborts the
  process), so the list is explicit installation prefixes —
  Homebrew on both architectures, then MacPorts.``
  (case (os/which)
    :macos ["/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib"
            "/usr/local/opt/openssl@3/lib/libcrypto.dylib"
            "/opt/homebrew/lib/libcrypto.3.dylib"
            "/usr/local/lib/libcrypto.3.dylib"
            "/opt/local/lib/libcrypto.dylib"]
    :windows ["libcrypto-3-x64.dll" "libcrypto-1_1-x64.dll"]
    ["libcrypto.so.3" "libcrypto.so.1.1" "libcrypto.so"]))

# -- bindings ------------------------------------------------------------

(def- registry
  "Every declared binding: {:symbol :ret :args :optional :install}."
  @[])

(defmacro- defssl
  ``Declare one libcrypto function: a module-level `var`, nil until
  `load!` installs the call. `& args` are ffi types; a trailing
  :optional marks a symbol that a supported-but-older library may not
  have.``
  [sym ret & args]
  (def optional (truthy? (index-of :optional args)))
  (def types (filter |(not= :optional $) args))
  ~(upscope
     (var ,sym nil)
     # `registry`, not `,registry`: unquoting an array splices an array
     # *literal*, and a literal builds a fresh array every evaluation —
     # each declaration would push into its own copy (see libpq.janet,
     # where this was learned)
     (array/push registry
                 {:symbol ,(string sym)
                  :ret ,ret
                  :args [,;types]
                  :optional ,optional
                  :install (fn [f] (set ,sym f))})))

# version and errors
(defssl OpenSSL_version_num :uint64)
(defssl OpenSSL_version :string :int)
(defssl ERR_get_error :uint64)
(defssl ERR_error_string_n :void :uint64 :ptr :size)

# message digests
(defssl EVP_sha256 :ptr)
(defssl EVP_sha384 :ptr)
(defssl EVP_sha512 :ptr)
(defssl EVP_sha1 :ptr)
(defssl EVP_Digest :int :ptr :size :ptr :ptr :ptr :ptr)
(defssl HMAC :ptr :ptr :ptr :int :ptr :size :ptr :ptr)

# constant-time comparison — the one primitive that is trivial to write
# and impossible to write correctly on an interpreter
(defssl CRYPTO_memcmp :int :ptr :ptr :size)

# key derivation
(defssl EVP_PBE_scrypt :int :ptr :size :ptr :size :uint64 :uint64 :uint64 :uint64 :ptr :size)
(defssl PKCS5_PBKDF2_HMAC :int :ptr :int :ptr :int :int :ptr :int :ptr)

# argon2id — OpenSSL 3.2+ only (see the module docstring)
(defssl EVP_KDF_fetch :ptr :ptr :string :ptr :optional)
(defssl EVP_KDF_free :void :ptr :optional)
(defssl EVP_KDF_CTX_new :ptr :ptr :optional)
(defssl EVP_KDF_CTX_free :void :ptr :optional)
(defssl EVP_KDF_derive :int :ptr :ptr :size :ptr :optional)

# signatures — RS256/ES256 for JWT (and void/oauth in wave 5)
(defssl BIO_new_mem_buf :ptr :ptr :int)
(defssl BIO_free :int :ptr)
(defssl PEM_read_bio_PUBKEY :ptr :ptr :ptr :ptr :ptr)
(defssl PEM_read_bio_PrivateKey :ptr :ptr :ptr :ptr :ptr)
(defssl EVP_PKEY_free :void :ptr)
(defssl EVP_PKEY_get_base_id :int :ptr :optional)
(defssl EVP_PKEY_get_size :int :ptr :optional)
(defssl EVP_MD_CTX_new :ptr)
(defssl EVP_MD_CTX_free :void :ptr)
(defssl EVP_DigestSignInit :int :ptr :ptr :ptr :ptr :ptr)
(defssl EVP_DigestSign :int :ptr :ptr :ptr :ptr :size)
(defssl EVP_DigestVerifyInit :int :ptr :ptr :ptr :ptr :ptr)
(defssl EVP_DigestVerify :int :ptr :ptr :size :ptr :size)

# -- loading -------------------------------------------------------------

(var library-path
  "Path `load!` opened, nil before that."
  nil)

(var library
  ``The open library object. Kept because `void/crypto/kdf` binds
  symbols off the handle directly rather than through the vars above:
  the same code has to run inside a worker thread, where this module's
  state does not exist.``
  nil)

(var missing
  "Symbols this library did not have — all of them optional, or
  `load!` would have failed. `algorithms` reads it."
  @[])

(defn available?
  "Has a libcrypto been loaded into these bindings?"
  []
  (not (nil? library-path)))

(defn candidates
  "The search order for a given configured path (nil = the defaults),
  environment override included."
  [&opt path]
  (cond
    path [path]
    (os/getenv path-env) [(os/getenv path-env)]
    default-candidates))

(defn- try-open [path]
  (def [ok lib] (protect (ffi/native path)))
  (when ok lib))

(defn load!
  ``Open libcrypto and install the bindings. `path` (from
  [:crypto :libcrypto]) is tried alone; without it the platform
  defaults are, in order. Idempotent for the same path — reopening a
  different one re-installs the bindings, which is what a REPL reload
  wants.

  Returns the path opened; throws naming every candidate tried,
  because "no libcrypto" is a message that has to say where it
  looked.``
  [&opt path]
  (when (and (available?) (or (nil? path) (= path library-path)))
    (break library-path))
  (def tried (candidates path))
  (var lib nil)
  (var found nil)
  (each c tried
    (unless lib
      (when-let [l (try-open c)]
        (set lib l)
        (set found c))))
  (unless lib
    (errorf (string "libcrypto not found — tried %s. Install OpenSSL 3 "
                    "(apt install libssl3, brew install openssl@3), or point "
                    "[:crypto :libcrypto] (or %s) at it")
            (string/join (map |(string/format "%q" $) tried) ", ")
            path-env))
  (def absent @[])
  (each b registry
    (def ptr (ffi/lookup lib (b :symbol)))
    (cond
      ptr
      (let [sig (ffi/signature :default (b :ret) ;(b :args))]
        ((b :install) (fn ssl-call [& args] (ffi/call ptr sig ;args))))

      (b :optional)
      (do (array/push absent (b :symbol))
          ((b :install) nil))

      (errorf "%s has no symbol %s — is it really libcrypto?" found (b :symbol))))
  (set missing absent)
  (set library library-path)
  (set library-path found)
  (set library lib)
  found)

(defn handle
  "The open library object, or nil — see the `library` var."
  []
  library)

(defn ensure!
  ``The library, or a readable error. Every module in this package
  calls it before its first ffi call, so "OpenSSL is not installed"
  reads as one sentence rather than as a nil call.``
  []
  (unless (available?)
    (errorf (string "void/crypto has no libcrypto open — add :void/crypto to "
                    ":plugins (it opens the library at :start), or call "
                    "(crypto/load!) directly. Looked in: %s")
            (string/join (map |(string/format "%q" $) (candidates)) ", ")))
  library-path)

# -- what this library can do -------------------------------------------

(defn version
  "The loaded library's version as [major minor patch], or nil before
  `load!`. OpenSSL encodes 3.2.1 as 0x30200010."
  []
  (when (available?)
    # :uint64 comes back as a core/u64 abstract, and every consumer of
    # this wants three plain numbers to compare against 3 and 2
    (def n (int/to-number (OpenSSL_version_num)))
    [(band (brshift n 28) 0xf)
     (band (brshift n 20) 0xff)
     (band (brshift n 4) 0xffff)]))

(defn version-text
  "What the library calls itself (OPENSSL_VERSION_STR = 0), or nil."
  []
  (when (available?) (OpenSSL_version 0)))

(defn algorithms
  ``What this particular library gives us, as a table of
  algorithm -> true/false. The interesting entry is :argon2id: it
  needs OpenSSL 3.2, and an LTS distribution may be on 3.0 — which is
  a fact about the machine, reported rather than guessed at.``
  []
  (if (available?)
    @{:sha1 true :sha256 true :sha384 true :sha512 true
      :hmac true :scrypt true :pbkdf2 true
      :argon2id (not (nil? EVP_KDF_fetch))
      :rs256 true :es256 true}
    @{}))

(defn last-error
  "The message OpenSSL left on its error queue, drained, or nil."
  []
  (when (available?)
    (def code (ERR_get_error))
    (unless (zero? (int/to-number code))
      (def buf (buffer/new-filled 256))
      (ERR_error_string_n code buf 256)
      # the C string inside the buffer, up to its NUL
      (def end (or (index-of 0 buf) (length buf)))
      (string (buffer/slice buf 0 end)))))
