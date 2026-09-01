# Serving the local store: one route, the static machinery behind it,
# and the two postures the prefix can take. Everything goes through
# test/inject, so what is asserted is the whole chain a socket request
# would run (ADR-0017).

(import ../test-support/paths)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/security/secret :as secret)
(import void/storage :as storage)
(import void/storage/sign :as sign)
(import void/test :as test)

(log/set-level! "void" :error)

(def root (string "tmp/http-test-" (os/getpid)))

(defn- rm-rf [path]
  (case (os/stat path :mode)
    :directory (do (each e (os/dir path) (rm-rf (string path "/" e)))
                   (os/rmdir path))
    :file (os/rm path)
    nil))

(rm-rf root)
(os/mkdir "tmp")

(def plugins ["void/http/init" "void/storage/init" "void/storage/http"])

(defn- start [storage-slice]
  (test/start! {:plugins plugins
                :profile :test
                :config {:env @{}
                         :cli {:log {:level :error}
                               # the root is this suite's own, and it is
                               # merged rather than replaced — a caller
                               # naming only :serve must not silently
                               # get the default root
                               :storage (merge {:local {:root root}}
                                               storage-slice)}}}))

# -- a public prefix -----------------------------------------------------

(def boot (start {:serve {:prefix "/files"}}))
(def c (test/client boot))

(defer (test/stop! boot)
  (storage/put! "products/logo.png" "PNG-BYTES" {})
  (storage/put! "docs/a b.txt" "spaces are legal in a key" {})

  (def resp (test/inject c {:uri "/files/products/logo.png"}))
  (assert (= 200 (resp :status)) "an object is served")
  (assert (= "PNG-BYTES" (test/text resp)))
  (assert (= "image/png" (get-in resp [:headers "content-type"]))
          "with the content type its extension implies")

  # the static machinery is the same one the stylesheet goes through,
  # which is the whole reason this route is three lines
  (def tag (get-in resp [:headers "etag"]))
  (assert tag "an upload gets a strong ETag")
  (def again (test/inject c {:uri "/files/products/logo.png"
                             :headers @{"if-none-match" tag}}))
  (assert (= 304 (again :status)) "and a conditional GET is answered 304")

  (def ranged (test/inject c {:uri "/files/products/logo.png"
                              :headers @{"range" "bytes=0-2"}}))
  (assert (= 206 (ranged :status)) "and a Range is a 206")
  (assert (= "PNG" (test/text ranged)))
  (assert (= "bytes 0-2/9" (get-in ranged [:headers "content-range"])))

  # the URL the store hands out is the URL that works
  (def url (storage/url "docs/a b.txt"))
  (assert (= "/files/docs/a%20b.txt" url))
  (assert (= 200 ((test/inject c {:uri url}) :status))
          "a percent-encoded key round-trips through the route")

  # -- what is not there, and what was never a key -----------------------

  (assert (= 404 ((test/inject c {:uri "/files/products/none.png"}) :status)))
  (each bad ["/files/../../etc/passwd"
             "/files/%2e%2e/%2e%2e/etc/passwd"
             "/files/"]
    (def r (test/inject c {:uri bad}))
    (assert (index-of (r :status) [400 404])
            (string/format "%q is refused, not served (%d)" bad (r :status))))

  # a public prefix serves a signed link too — it simply does not
  # demand one
  (crypto/load!)
  (secret/configure! {:signing-key (string/repeat "k" 32)} :test)
  (def p (sign/params "products/logo.png" 600))
  (assert (= 200 ((test/inject c {:uri (string "/files/products/logo.png"
                                               "?exp=" (p "exp") "&sig=" (p "sig"))})
                   :status))
          "a signed link works against a public prefix"))

# -- a private prefix ----------------------------------------------------

(crypto/load!)
(secret/configure! {:signing-key (string/repeat "k" 32)} :test)

(def sboot (start {:serve {:prefix "/private" :signed true}}))
(def sc (test/client sboot))

(defer (do (test/stop! sboot) (rm-rf root))
  (storage/put! "receipts/2026.pdf" "%PDF-1.7" {})

  (assert (= 403 ((test/inject sc {:uri "/private/receipts/2026.pdf"}) :status))
          "a private prefix serves nothing without a signature")

  (def url (storage/url "receipts/2026.pdf" {:expires 600}))
  (assert (string/find "exp=" url) "the store's url mints one when asked")
  (assert (string/find "sig=" url))
  (assert (= 200 ((test/inject sc {:uri url}) :status))
          "and that link opens the object")

  (def expired (storage/url "receipts/2026.pdf" {:expires 1}))
  (def [_ q] (string/split "?" expired))
  (def parts (string/split "&" q))
  (def exp (string/slice (first parts) 4))
  (def sig (string/slice (last parts) 4))
  (assert (not (sign/valid? "receipts/2026.pdf" exp sig (+ (os/time) 2)))
          "and it stops verifying when it expires")

  (assert (= 403 ((test/inject sc {:uri (string "/private/receipts/2026.pdf"
                                                "?exp=" exp "&sig=AAAA")})
                   :status))
          "a tampered signature is the same 403 as none at all")

  # the signature is over the key: a link to one object does not open
  # another
  (storage/put! "receipts/other.pdf" "%PDF-1.7" {})
  (def other (storage/url "receipts/2026.pdf" {:expires 600}))
  (def [path oq] (string/split "?" other))
  (assert (= 403 ((test/inject sc {:uri (string "/private/receipts/other.pdf?" oq)})
                   :status))
          "one object's link does not open another's"))

# -- the posture the application takes ------------------------------------
#
# The route carries no policy of its own, because this plugin does not
# know the policy names of the application it lands in. Under
# [:authz :default :deny] that is a refusal to start naming this route
# — silence must not mean public under a deny posture — and
# [:storage :serve :policy] is the one line that answers it.

(def deny-plugins
  ["void/http/init" "void/authz/init" "void/authz/http"
   "void/storage/init" "void/storage/http"])

(defn- deny-boot [serve]
  (protect
    (test/start! {:plugins deny-plugins
                  :profile :test
                  :only [:http/kernel :authz/registry]
                  :config {:env @{}
                           :cli {:log {:level :error}
                                 :authz {:default :deny}
                                 :storage {:local {:root root} :serve serve}}}})))

(def [silent err] (deny-boot {:prefix "/files"}))
(assert (not silent) "under :deny a serve route with no policy does not start")
(assert (string/find "void.storage/serve" (string err))
        "and the refusal names the route, so the line to write is obvious")

(def [named nboot] (deny-boot {:prefix "/files" :policy :public}))
(assert named "and [:storage :serve :policy] is that line")
(when named
  (test/stop! nboot))
(rm-rf root)

(printf "http-test: ok")
