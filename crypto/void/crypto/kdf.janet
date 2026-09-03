### void/crypto/kdf — key derivation, off the event loop.
###
### Three functions, one shape: bytes in, bytes out, every parameter
### explicit. Password *encoding* (the PHC string that says which
### function and which cost produced a hash) is not here — it belongs
### to whoever stores passwords, which is `void/auth`. This module
### derives.
###
### **Why every derivation goes through `derive`.** A KDF is a
### deliberately expensive, entirely synchronous computation: scrypt at
### the default cost takes ~25 ms of pure CPU. On a single-threaded ev
### loop that is 25 ms during which the worker answers nobody — measured,
### with a 2 ms ticker as the witness:
###
###     on the loop        25.3 ms   ticker ran 0 times
###     through ev/thread  36.9 ms   ticker ran 17 times
###
### So the default is `ev/thread`. The ~11 ms it adds is the thread
### plus a second `ffi/native` — an ffi handle cannot cross a VM
### boundary, so the worker re-opens the library by path — and it is
### paid only on the login path, against 25 ms of a frozen worker on
### every login attempt. `[:crypto :kdf :in-thread false]` puts it back
### on the loop for tests, CLI and single-shot scripts.
###
### **Why the worker binds its own symbols.** `thread-work` deliberately
### takes a *path* and does its own `ffi/native` / `ffi/lookup`: a
### function that closed over ./lib's vars would have to marshal an ffi
### native object into the new VM, and that is exactly the thing that
### cannot be marshalled. Everything the worker touches is plain data.
###
### If those 11 ms ever matter, the next step is known and local: one
### long-lived worker thread instead of one per derivation.

(import ./lib :as lib)

(def defaults
  ``Cost parameters, and the arguments for them.

  scrypt N=16384 r=8 p=1 is ~25 ms and 16 MiB per hash on 2026
  hardware — the interactive setting from RFC 7914 §2 raised one
  notch, which is where the "under 100 ms, over 10 ms" advice for a
  login form lands.

  argon2id t=2 m=64 MiB lanes=1 is the OWASP second-choice profile
  (m=64 MiB, t=2, p=1). It is not the default because it needs
  OpenSSL 3.2 and an LTS distribution may not have it.

  PBKDF2 600k iterations is OWASP's 2023 number for HMAC-SHA256. It
  is here for compatibility with hashes that arrive from another
  stack, not as a choice for new passwords.``
  {:scrypt {:n 16384 :r 8 :p 1 :length 32 :maxmem (* 64 1024 1024)}
   :argon2id {:t 2 :m 65536 :lanes 1 :length 32}
   :pbkdf2 {:iterations 600000 :length 32 :digest :sha256}})

(var in-thread
  ``Run derivations on a worker thread instead of the ev loop. True by
  default (see the module docstring); the plugin sets it from
  [:crypto :kdf :in-thread].``
  true)

# -- the computation, over an already-open library -----------------------

(defn- bound [handle name ret & argtypes]
  (def ptr (ffi/lookup handle name))
  (unless ptr (errorf "%s is not in this libcrypto" name))
  (def sig (ffi/signature :default ret ;argtypes))
  (fn [& args] (ffi/call ptr sig ;args)))

(def- param-size
  ``sizeof(OSSL_PARAM) on a 64-bit ABI: char *key(0), unsigned int
  data_type(8) with four bytes of padding after it, void *data(16),
  size_t data_size(24), size_t return_size(32).``
  40)

(def- param-utf8-string 4)
(def- param-octet-string 5)
(def- param-unsigned-integer 2)

(defn- ossl-params
  ``Build an OSSL_PARAM array from [name kind value] triples, kind
  being :octets or :uint, terminated by OSSL_PARAM_END. Returns
  [buffer roots] — `roots` holds every janet value the array points
  into, and the caller must keep it alive until the call returns, or
  the GC is free to collect what C is about to read.``
  [triples]
  (def n (length triples))
  (def buf (buffer/new-filled (* param-size (inc n))))
  (def roots @[])
  (eachp [i [name kind value]] triples
    (def off (* i param-size))
    (def key (string name))
    (array/push roots key)
    (ffi/write :string key buf off)
    (case kind
      # A buffer and :ptr, never :string. An OSSL_PARAM carries a
      # pointer *and* a length, so what it points at is allowed to
      # contain zero bytes — and `ffi/write :string` is not: it
      # refuses embedded zeroes, because a C string ends at the first
      # one. A random 16-byte salt contains a zero roughly once in
      # sixteen, which is what made hashing fail for one password in
      # sixteen and nothing else. The capacity is at least one byte so
      # that an empty value still has an address to point at.
      :octets
      (let [v (string value)
            cell (buffer/new (max 1 (length v)))]
        (buffer/push cell v)
        (array/push roots cell)
        (ffi/write :uint32 param-octet-string buf (+ off 8))
        (ffi/write :ptr cell buf (+ off 16))
        (ffi/write :uint64 (length v) buf (+ off 24)))

      :utf8
      (let [v (string value)
            cell (buffer/new (max 1 (length v)))]
        (buffer/push cell v)
        (array/push roots cell)
        (ffi/write :uint32 param-utf8-string buf (+ off 8))
        (ffi/write :ptr cell buf (+ off 16))
        (ffi/write :uint64 (length v) buf (+ off 24)))

      :uint
      (let [cell (buffer/new-filled 4)]
        (ffi/write :uint32 value cell 0)
        (array/push roots cell)
        (ffi/write :uint32 param-unsigned-integer buf (+ off 8))
        (ffi/write :ptr cell buf (+ off 16))
        (ffi/write :uint64 4 buf (+ off 24)))

      (errorf "unknown OSSL_PARAM kind %q" kind)))
  [buf roots])

(defn- digest-md [handle name]
  ((bound handle name :ptr)))

(defn derive-with
  ``One derivation over an already-open library handle. `spec` is
  plain data — this function is what runs inside the worker thread,
  so it may not touch this module's state or ./lib's bindings.

  spec: {:kind :scrypt|:pbkdf2|:argon2id :password :salt ...}``
  [handle spec]
  (def password (string (spec :password)))
  (def salt (string (spec :salt)))
  # `size`, not `length`: binding that name here would shadow the
  # function every call below uses
  (def size (spec :length))
  (def out (buffer/new-filled size))
  (case (spec :kind)
    :scrypt
    (let [f (bound handle "EVP_PBE_scrypt" :int
                   :ptr :size :ptr :size :uint64 :uint64 :uint64 :uint64 :ptr :size)
          rc (f password (length password) salt (length salt)
                (spec :n) (spec :r) (spec :p) (spec :maxmem)
                out size)]
      (unless (= 1 rc)
        (error "EVP_PBE_scrypt failed — check that N is a power of two above 1 and that :maxmem covers 128 * N * r bytes")))

    :pbkdf2
    (let [md (digest-md handle (case (spec :digest)
                                 :sha256 "EVP_sha256"
                                 :sha512 "EVP_sha512"
                                 :sha1 "EVP_sha1"
                                 (errorf "pbkdf2: unknown digest %q" (spec :digest))))
          f (bound handle "PKCS5_PBKDF2_HMAC" :int
                   :ptr :int :ptr :int :int :ptr :int :ptr)
          rc (f password (length password) salt (length salt)
                (spec :iterations) md size out)]
      (unless (= 1 rc) (error "PKCS5_PBKDF2_HMAC failed")))

    :argon2id
    (do
      (unless (ffi/lookup handle "EVP_KDF_fetch")
        (error "argon2id needs OpenSSL 3.2 or newer; this library has no EVP_KDF_fetch. Use :scrypt, or install a newer OpenSSL"))
      (def fetch (bound handle "EVP_KDF_fetch" :ptr :ptr :string :ptr))
      (def kdf-free (bound handle "EVP_KDF_free" :void :ptr))
      (def ctx-new (bound handle "EVP_KDF_CTX_new" :ptr :ptr))
      (def ctx-free (bound handle "EVP_KDF_CTX_free" :void :ptr))
      (def derive (bound handle "EVP_KDF_derive" :int :ptr :ptr :size :ptr))
      (def kdf (fetch nil "ARGON2ID" nil))
      (unless kdf
        (error (string "argon2id needs OpenSSL 3.2 or newer; this library has the EVP_KDF "
                       "interface but no ARGON2ID behind it. Use :scrypt, or install "
                       "a newer OpenSSL")))
      (def ctx (ctx-new kdf))
      (kdf-free kdf)
      (unless ctx (error "EVP_KDF_CTX_new failed"))
      (def [params roots]
        (ossl-params
          [["pass" :octets password]
           ["salt" :octets salt]
           ["iter" :uint (spec :t)]
           ["memcost" :uint (spec :m)]
           ["lanes" :uint (spec :lanes)]
           # threads > 1 would need OSSL_set_max_threads and a thread pool
           # inside a process that already has its own concurrency model;
           # lanes are the parallelism knob that costs nothing here
           ["threads" :uint 1]
           # the pepper: a key held by the application, not by the
           # database, so a dump of the password column is not enough to
           # start guessing. argon2 takes it natively — scrypt does not,
           # which is one thing argon2id is genuinely better at
           ;(if-let [k (spec :secret)] [["secret" :octets k]] [])
           ;(if-let [ad (spec :ad)] [["ad" :octets ad]] [])]))
      (def rc (derive ctx out size params))
      (ctx-free ctx)
      # `roots` holds the janet values `params` points into; C read them
      # during the call above and janet reads them nowhere, so this is
      # the line that keeps the GC off them until it is over
      (assert (not (empty? roots)) "OSSL_PARAM roots must outlive the call")
      (unless (= 1 rc) (error "EVP_KDF_derive(ARGON2ID) failed")))

    (errorf "unknown kdf %q" (spec :kind)))
  (string out))

# -- running it somewhere sensible ---------------------------------------

(defn thread-work
  ``The worker thread's body: open the library by path, derive, answer
  on the channel. Takes plain data only (see the module docstring) —
  `payload` is [channel library-path spec].``
  [payload]
  (def [ch path spec] payload)
  (def [ok res] (protect (derive-with (ffi/native path) spec)))
  (ev/give ch (if ok [:ok res] [:error (string res)])))

(defn derive
  ``Derive a key from `spec` — on a worker thread unless `in-thread`
  is false. Returns raw bytes.``
  [spec]
  (def path (lib/ensure!))
  (if in-thread
    (let [ch (ev/thread-chan 1)]
      (ev/thread thread-work [ch path spec])
      (def [status value] (ev/take ch))
      (if (= :ok status) value (error value)))
    (derive-with (lib/handle) spec)))

# -- the three functions -------------------------------------------------

(defn scrypt
  ``scrypt (RFC 7914) over a password and a salt. Options override
  `defaults`: :n (CPU/memory cost, a power of two), :r, :p, :length,
  :maxmem.``
  [password salt &opt opts]
  (derive (merge {:kind :scrypt} (defaults :scrypt) (or opts {})
                 {:password password :salt salt})))

(defn pbkdf2
  "PBKDF2-HMAC over a password and a salt. Options: :iterations,
  :length, :digest (:sha256 :sha512 :sha1)."
  [password salt &opt opts]
  (derive (merge {:kind :pbkdf2} (defaults :pbkdf2) (or opts {})
                 {:password password :salt salt})))

(defn argon2id
  ``argon2id over a password and a salt — OpenSSL 3.2+ only, see
  `(crypto/algorithms)`. Options: :t (passes), :m (memory in KiB),
  :lanes, :length, :secret (a pepper the application holds and the
  database does not) and :ad (associated data).``
  [password salt &opt opts]
  (derive (merge {:kind :argon2id} (defaults :argon2id) (or opts {})
                 {:password password :salt salt})))

(defn available?
  "Can this library derive with `kind`?"
  [kind]
  (truthy? (get (lib/algorithms) kind)))
