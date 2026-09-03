### void/tls/lib — the libssl surface void uses, and nothing more
###
### The same decision `void/crypto/lib` made, made again for the other
### half of the OpenSSL installation: bindings are `var`s installed by
### `load!` at component :start, nil until then, so a plugin that merely
### gets *loaded* — `plugin/dry-run` in CI, `void routes` on a laptop —
### never explodes on import. The candidate list is written out by
### platform because of the macOS trap void/crypto documents: on macOS 15
### the system LibreSSL shim *aborts the process* when opened by bare
### name, so the macOS list is explicit installation prefixes only, never
### a bare soname, never /usr/lib. `VOID_LIBSSL` is the escape hatch.
###
### Only `SSL_*` symbols live here. `BIO_*`, `ERR_*` and
### `X509_verify_cert_error_string` are libcrypto symbols, and void
### already has a libcrypto open — `void/crypto`'s (this package
### requires it). `load!` binds those off crypto's handle, so there is
### one crypto stack in the process, not one and a half.

(import void/crypto/lib :as crypto-lib)

(def path-env
  "Environment variable that overrides the search."
  "VOID_LIBSSL")

(def default-candidates
  ``Where libssl is looked for when nothing is configured, in order —
  the same shape and the same reasoning as crypto-lib's list (its
  docstring has the macOS abort story).``
  (case (os/which)
    :macos ["/opt/homebrew/opt/openssl@3/lib/libssl.dylib"
            "/usr/local/opt/openssl@3/lib/libssl.dylib"
            "/opt/homebrew/lib/libssl.3.dylib"
            "/usr/local/lib/libssl.3.dylib"
            "/opt/local/lib/libssl.dylib"]
    :windows ["libssl-3-x64.dll" "libssl-1_1-x64.dll"]
    ["libssl.so.3" "libssl.so.1.1" "libssl.so"]))

# -- constants (openssl/ssl.h) -------------------------------------------

(def SSL-VERIFY-NONE 0)
(def SSL-VERIFY-PEER 1)
(def SSL-FILETYPE-PEM 1)
(def SSL-CTRL-SET-MIN-PROTO-VERSION 123)
(def SSL-CTRL-SET-TLSEXT-HOSTNAME 55)
(def TLSEXT-NAMETYPE-host-name 0)
(def TLS1-2-VERSION 0x0303)
(def TLS1-3-VERSION 0x0304)

# SSL_get_error answers
(def SSL-ERROR-NONE 0)
(def SSL-ERROR-SSL 1)
(def SSL-ERROR-WANT-READ 2)
(def SSL-ERROR-WANT-WRITE 3)
(def SSL-ERROR-SYSCALL 5)
(def SSL-ERROR-ZERO-RETURN 6)

# X509_V_OK — everything else is a verification failure with a name
(def X509-V-OK 0)

# -- bindings ------------------------------------------------------------

(def- ssl-registry
  "Every declared libssl binding: {:symbol :ret :args :install}."
  @[])

(defmacro- defssl
  "Declare one libssl function: a module-level `var`, nil until `load!`
  installs the call."
  [sym ret & args]
  ~(upscope
     (var ,sym nil)
     # `ssl-registry`, not `,ssl-registry`: an unquoted array splices a
     # literal that is rebuilt per evaluation (see crypto/lib.janet)
     (array/push ssl-registry
                 {:symbol ,(string sym)
                  :ret ,ret
                  :args [,;args]
                  :install (fn [f] (set ,sym f))})))

(defssl OpenSSL_version_num :uint64)
(defssl TLS_client_method :ptr)
(defssl TLS_server_method :ptr)
(defssl SSL_CTX_new :ptr :ptr)
(defssl SSL_CTX_free :void :ptr)
(defssl SSL_CTX_ctrl :long :ptr :int :long :ptr)
(defssl SSL_CTX_set_verify :void :ptr :int :ptr)
(defssl SSL_CTX_set_default_verify_paths :int :ptr)
(defssl SSL_CTX_load_verify_locations :int :ptr :ptr :ptr)
(defssl SSL_CTX_use_certificate_chain_file :int :ptr :ptr)
(defssl SSL_CTX_use_PrivateKey_file :int :ptr :ptr :int)
(defssl SSL_new :ptr :ptr)
(defssl SSL_free :void :ptr)
(defssl SSL_set_bio :void :ptr :ptr :ptr)
(defssl SSL_set_connect_state :void :ptr)
(defssl SSL_set_accept_state :void :ptr)
(defssl SSL_ctrl :long :ptr :int :long :ptr)
(defssl SSL_set1_host :int :ptr :ptr)
(defssl SSL_do_handshake :int :ptr)
(defssl SSL_get_error :int :ptr :int)
(defssl SSL_read_ex :int :ptr :ptr :size :ptr)
(defssl SSL_write_ex :int :ptr :ptr :size :ptr)
(defssl SSL_shutdown :int :ptr)
(defssl SSL_get_verify_result :long :ptr)
# the verify parameters of one SSL — the way an IP peer is pinned
# (X509_VERIFY_PARAM_set1_ip_asc below; SSL_set1_host checks DNS
# names, and "127.0.0.1" is not one)
(defssl SSL_get0_param :ptr :ptr)
# documented to return a static string, never NULL — :string is safe
(defssl SSL_get_version :string :ptr)

# libcrypto symbols this package needs, bound off void/crypto's handle
# by `load!` — see the module docstring
(var BIO_new nil)
(var BIO_s_mem nil)
(var BIO_read nil)
(var BIO_write nil)
(var BIO_ctrl_pending nil)
(var X509_verify_cert_error_string nil)
(var X509_VERIFY_PARAM_set1_ip_asc nil)

(def- crypto-symbols
  [["BIO_new" :ptr [:ptr] (fn [f] (set BIO_new f))]
   ["BIO_s_mem" :ptr [] (fn [f] (set BIO_s_mem f))]
   ["BIO_read" :int [:ptr :ptr :int] (fn [f] (set BIO_read f))]
   ["BIO_write" :int [:ptr :ptr :int] (fn [f] (set BIO_write f))]
   ["BIO_ctrl_pending" :size [:ptr] (fn [f] (set BIO_ctrl_pending f))]
   # returns a static message table entry — non-NULL for any code
   ["X509_verify_cert_error_string" :string [:long]
    (fn [f] (set X509_verify_cert_error_string f))]
   ["X509_VERIFY_PARAM_set1_ip_asc" :int [:ptr :ptr]
    (fn [f] (set X509_VERIFY_PARAM_set1_ip_asc f))]])

# -- loading -------------------------------------------------------------

(var library-path
  "Path `load!` opened, nil before that."
  nil)

(var library
  "The open libssl object."
  nil)

(defn available?
  "Has a libssl been loaded into these bindings?"
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

(defn- bind-off [lib symbol ret args install missing-fmt]
  (def ptr (ffi/lookup lib symbol))
  (unless ptr (errorf missing-fmt symbol))
  (def sig (ffi/signature :default ret ;args))
  (install (fn tls-call [& a] (ffi/call ptr sig ;a))))

(defn load!
  ``Open libssl (and make sure void/crypto's libcrypto is open — the
  BIO and error-string symbols come off its handle) and install the
  bindings. Idempotent for the same path. Returns the path opened;
  throws naming every candidate tried.``
  [&opt path]
  (when (and (available?) (or (nil? path) (= path library-path)))
    (break library-path))
  # libcrypto first: same installation family, and the place BIO lives.
  # crypto-lib/load! is idempotent and respects its own configuration.
  (crypto-lib/load!)
  (def tried (candidates path))
  (var lib nil)
  (var found nil)
  (each c tried
    (unless lib
      (when-let [l (try-open c)]
        (set lib l)
        (set found c))))
  (unless lib
    (errorf (string "libssl not found — tried %s. Install OpenSSL 3 "
                    "(apt install libssl3, brew install openssl@3), or point "
                    "[:tls :libssl] (or %s) at it")
            (string/join (map |(string/format "%q" $) tried) ", ")
            path-env))
  (each b ssl-registry
    (bind-off lib (b :symbol) (b :ret) (b :args) (b :install)
              (string found " has no symbol %s — is it really libssl?")))
  (def ch (crypto-lib/handle))
  (each [symbol ret args install] crypto-symbols
    (bind-off ch symbol ret args install
              (string (crypto-lib/ensure!) " has no symbol %s — is it really libcrypto?")))
  (set library lib)
  (set library-path found)
  found)

(defn ensure!
  "The library path, or a readable error naming the way in."
  []
  (unless (available?)
    (errorf (string "void/tls has no libssl open — add :void/tls to :plugins "
                    "(it opens the library at :start), or call (tls/load!) "
                    "directly. Looked in: %s")
            (string/join (map |(string/format "%q" $) (candidates)) ", ")))
  library-path)

(defn version
  "The loaded libssl's version as [major minor patch], or nil."
  []
  (when (available?)
    (def n (int/to-number (OpenSSL_version_num)))
    [(band (brshift n 28) 0xf)
     (band (brshift n 20) 0xff)
     (band (brshift n 4) 0xffff)]))

(defn last-error
  "The message OpenSSL left on its error queue (crypto-lib drains it),
  or nil."
  []
  (crypto-lib/last-error))
