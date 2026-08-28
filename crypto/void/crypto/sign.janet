### void/crypto/sign — asymmetric signatures for JWS (ADR-0022 §1).
###
### RS256/384/512 (RSASSA-PKCS1-v1_5) and ES256/384/512 (ECDSA on the
### P-curves) over `EVP_DigestSign`/`EVP_DigestVerify`. They are here
### because the decision to take *all* crypto from libcrypto makes them
### four bindings rather than a project: `void/auth`'s JWT strategy
### verifies tokens from an identity provider with them today, and
### `void/oauth` (wave 5) needs nothing else.
###
### **Keys are opened, not parsed on every call.** `public-key` and
### `private-key` hand back a C pointer that must be released with
### `free-key`; there is no finalizer, because janet's `ffi/` has none
### to give. The intended lifetime is the process: a plugin opens the
### issuer's key at `:start` and never closes it. Anything that opens a
### key per request will leak, and that is documented rather than
### defended against — the alternative (re-parsing PEM on every token)
### is a hundred microseconds of the same work on the hot path.
###
### **ECDSA signatures are converted.** OpenSSL produces the DER
### encoding of `SEQUENCE { INTEGER r, INTEGER s }`; JWS (RFC 7515
### §3.4) wants the raw fixed-width `r || s`. The two conversions below
### are the whole difference, and getting them wrong is the classic
### interop bug: a DER integer carries a leading zero byte when its top
### bit is set, and drops leading zeroes otherwise, so both padding and
### stripping have to happen.

(import ./lib :as lib)

(def- nid-rsa 6)
(def- nid-ec 408)

(def algorithms
  ``Supported JWS algorithms: digest, key type and — for ECDSA — the
  coordinate width the raw signature is padded to.``
  {:rs256 {:digest "EVP_sha256" :kind :rsa}
   :rs384 {:digest "EVP_sha384" :kind :rsa}
   :rs512 {:digest "EVP_sha512" :kind :rsa}
   :es256 {:digest "EVP_sha256" :kind :ec :width 32}
   :es384 {:digest "EVP_sha384" :kind :ec :width 48}
   :es512 {:digest "EVP_sha512" :kind :ec :width 66}})

(defn- spec-of [algo]
  (or (algorithms algo)
      (errorf "unknown signature algorithm %q (have %s)" algo
              (string/join (map string (sorted (keys algorithms))) " "))))

(defn- md-of [algo]
  (case (get (spec-of algo) :digest)
    "EVP_sha256" (lib/EVP_sha256)
    "EVP_sha384" (lib/EVP_sha384)
    "EVP_sha512" (lib/EVP_sha512)))

# -- keys ----------------------------------------------------------------

(defn- read-key [pem public?]
  (lib/ensure!)
  (def text (string pem))
  (def bio (lib/BIO_new_mem_buf text (length text)))
  (unless bio (error "BIO_new_mem_buf failed"))
  (def pkey (if public?
              (lib/PEM_read_bio_PUBKEY bio nil nil nil)
              (lib/PEM_read_bio_PrivateKey bio nil nil nil)))
  (lib/BIO_free bio)
  (unless pkey
    (errorf "not a %s key in PEM form: %s"
            (if public? "public" "private")
            (or (lib/last-error) "no detail")))
  (def kind
    (if lib/EVP_PKEY_get_base_id
      (case (lib/EVP_PKEY_get_base_id pkey)
        nid-rsa :rsa
        nid-ec :ec
        :other)
      # OpenSSL 1.1 spelled it EVP_PKEY_base_id; on a library without
      # the 3.0 name the type check simply does not happen, and a
      # mismatched key fails at the sign/verify call instead
      :unknown))
  {:pkey pkey :kind kind :public public?})

(defn public-key
  "Open a PEM public key (SubjectPublicKeyInfo). Release it with
  `free-key`; see the module docstring about lifetimes."
  [pem]
  (read-key pem true))

(defn private-key
  "Open a PEM private key (PKCS#8 or the traditional forms libcrypto
  accepts). Release it with `free-key`."
  [pem]
  (read-key pem false))

(defn free-key
  "Release a key opened by `public-key` / `private-key`."
  [key]
  (when (and key (key :pkey))
    (lib/EVP_PKEY_free (key :pkey))
    nil))

(defn- check-kind [key algo]
  (def want (get (spec-of algo) :kind))
  (def have (key :kind))
  (when (and (not= have :unknown) (not= have want))
    (errorf "%q needs %s key, got %s" algo
            (if (= want :rsa) "an RSA" "an EC")
            (case have :rsa "RSA" :ec "EC" "another kind of"))))

# -- ECDSA: DER <-> the fixed-width pair JWS wants -----------------------

(defn- der-integer
  "Read one DER INTEGER at `pos`; returns [bytes next-pos]."
  [der pos]
  (unless (= 0x02 (der pos))
    (errorf "ECDSA signature: expected INTEGER at %d, got 0x%02x" pos (der pos)))
  (def len (der (inc pos)))
  (when (>= len 0x80)
    (error "ECDSA signature: an INTEGER longer than 127 bytes is not a P-curve coordinate"))
  [(string/slice der (+ pos 2) (+ pos 2 len)) (+ pos 2 len)])

(defn- pad-left [bytes width]
  (def b (string bytes))
  # a DER INTEGER is signed: a coordinate whose top bit is set carries
  # a leading zero byte, and one with leading zero bytes has them
  # dropped. JWS wants exactly `width` bytes, so both cases are fixed
  # here
  (def trimmed
    (do (var i 0)
        (while (and (< i (dec (length b))) (zero? (b i))) (++ i))
        (string/slice b i)))
  (when (> (length trimmed) width)
    (errorf "ECDSA coordinate is %d bytes, wider than the curve's %d"
            (length trimmed) width))
  (string (string/repeat "\x00" (- width (length trimmed))) trimmed))

(defn- der->raw [der width]
  (unless (and (>= (length der) 2) (= 0x30 (der 0)))
    (error "ECDSA signature: not a DER SEQUENCE"))
  (def body-start (if (>= (der 1) 0x80) (+ 2 (- (der 1) 0x80)) 2))
  (def [r after-r] (der-integer der body-start))
  (def [s _] (der-integer der after-r))
  (string (pad-left r width) (pad-left s width)))

(defn- der-int-bytes [raw]
  (def b
    (do (var i 0)
        (while (and (< i (dec (length raw))) (zero? (raw i))) (++ i))
        (string/slice raw i)))
  (if (>= (b 0) 0x80) (string "\x00" b) b))

(defn- raw->der [raw width]
  (unless (= (length raw) (* 2 width))
    (errorf "ECDSA signature: %d bytes, expected %d" (length raw) (* 2 width)))
  (def r (der-int-bytes (string/slice raw 0 width)))
  (def s (der-int-bytes (string/slice raw width)))
  (def body (string "\x02" (string/from-bytes (length r)) r
                    "\x02" (string/from-bytes (length s)) s))
  (def header
    (if (< (length body) 0x80)
      (string "\x30" (string/from-bytes (length body)))
      (string "\x30\x81" (string/from-bytes (length body)))))
  (string header body))

# -- sign and verify -----------------------------------------------------

(defn sign
  ``Sign bytes with a private key. Returns the signature in **JWS
  form**: PKCS#1 v1.5 for RS*, the raw `r || s` pair for ES*.``
  [key algo data]
  (lib/ensure!)
  (check-kind key algo)
  (def ctx (lib/EVP_MD_CTX_new))
  (unless ctx (error "EVP_MD_CTX_new failed"))
  (defn fail [what]
    (lib/EVP_MD_CTX_free ctx)
    (errorf "%s failed: %s" what (or (lib/last-error) "no detail")))
  (unless (= 1 (lib/EVP_DigestSignInit ctx nil (md-of algo) nil (key :pkey)))
    (fail "EVP_DigestSignInit"))
  # two calls: the first asks how long the signature will be (sigret
  # NULL), the second writes it
  (def lenbuf (buffer/new-filled 8))
  (unless (= 1 (lib/EVP_DigestSign ctx nil lenbuf data (length data)))
    (fail "EVP_DigestSign (size)"))
  (def cap (int/to-number (ffi/read :uint64 lenbuf 0)))
  (def out (buffer/new-filled cap))
  (unless (= 1 (lib/EVP_DigestSign ctx out lenbuf data (length data)))
    (fail "EVP_DigestSign"))
  (def written (int/to-number (ffi/read :uint64 lenbuf 0)))
  (lib/EVP_MD_CTX_free ctx)
  (def sig (string (buffer/slice out 0 written)))
  (if-let [width (get (spec-of algo) :width)]
    (der->raw sig width)
    sig))

(defn verify
  ``Verify a JWS-form signature over bytes with a public key. Returns
  true or false; a malformed signature is false, not an error —
  "this token is not valid" is one answer, and a caller that had to
  tell malformed from wrong would write the same `if` twice.``
  [key algo data signature]
  (lib/ensure!)
  (check-kind key algo)
  (def spec (spec-of algo))
  (def [ok sig]
    (if-let [width (spec :width)]
      (protect (raw->der (string signature) width))
      [true (string signature)]))
  (if (not ok)
    false
    (do
      (def ctx (lib/EVP_MD_CTX_new))
      (unless ctx (error "EVP_MD_CTX_new failed"))
      (def started (lib/EVP_DigestVerifyInit ctx nil (md-of algo) nil (key :pkey)))
      (def rc (when (= 1 started)
                (lib/EVP_DigestVerify ctx sig (length sig) data (length data))))
      (lib/EVP_MD_CTX_free ctx)
      # a failed verification leaves an entry on OpenSSL's error queue;
      # draining it here keeps the next unrelated error message honest
      (lib/last-error)
      (= 1 rc))))
