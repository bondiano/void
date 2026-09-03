(import ../test-support/paths)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/security/secret :as secret)
(import void/security/csrf :as csrf)

(log/set-level! "void.security.secret" :error)
(crypto/load!)
(secret/configure! {:signing-key (string/repeat "k" 32)} :prod)

# -- the token -----------------------------------------------------------

(def token (csrf/issue "session-abc"))
(assert (= 3 (length (string/split "." token))) "nonce, timestamp, signature")
(assert (csrf/verify token "session-abc"))
(assert (not (csrf/verify token "session-xyz"))
        "a token minted for one browser does not verify for another — the binding is in the signature")
(assert (not (csrf/verify (string token "x") "session-abc")))
(assert (not (csrf/verify (string/slice token 0 -2) "session-abc")))
(assert (not (csrf/verify "" "session-abc")))
(assert (not (csrf/verify nil "session-abc")))
(assert (not (csrf/verify token nil)) "and a request with nothing to bind to cannot pass")
(assert (not= token (csrf/issue "session-abc")) "every token is fresh")

(def old (csrf/issue "s" (- (os/time) 100000)))
(assert (not (csrf/verify old "s")) "a stale token is refused")
(assert (csrf/verify old "s" {:max-age 200000}) "for as long as :max-age says, and no longer")
(assert (not (csrf/verify (csrf/issue "s" (+ (os/time) 5000)) "s"))
        "and one from the future is refused too — that is a clock or a forgery")

# a token signed with another key does not verify here
(secret/configure! {:signing-key (string/repeat "j" 32)} :prod)
(assert (not (csrf/verify token "session-abc")))
(secret/configure! {:signing-key (string/repeat "j" 32) :previous-keys [(string/repeat "k" 32)]} :prod)
(assert (csrf/verify token "session-abc") "unless the old key is still in the rotation")

# -- when it applies -----------------------------------------------------

(def cfg csrf/defaults)

(defn- req [method &opt cookies identity]
  @{:method method
    :headers (if cookies @{"cookie" cookies} @{})
    :void.auth/identity identity})

(assert (not (csrf/applies? (req :get "void-session=abc") {} cfg)) "GET is safe")
(assert (not (csrf/applies? (req :head "void-session=abc") {} cfg)))
(assert (csrf/applies? (req :post "void-session=abc") {} cfg)
        "a POST carrying a session cookie is exactly the shape CSRF attacks")
(assert (csrf/applies? (req :delete "void-session=abc") {} cfg))

(assert (not (csrf/applies? (req :post) {} cfg))
        "a POST with no cookie at all cannot be forged by another origin")
(assert (not (csrf/applies? (req :post nil {:subject "user:1" :cookie false}) {} cfg))
        "and neither can one whose identity came from an Authorization header")
(assert (csrf/applies? (req :post nil {:subject "user:1" :cookie true}) {} cfg)
        "while an identity a cookie-reading strategy established is checked — void/auth records which it was")

(assert (csrf/applies? (req :post) {:void.security/csrf true} cfg)
        "a route may demand the token unconditionally")
(assert (not (csrf/applies? (req :post "void-session=abc") {} (merge cfg {:enabled false})))
        "and the whole check can be turned off in configuration, which is not the same as per route")

# -- where the token arrives from ----------------------------------------

(def with-field @{:method :post :headers @{} :form @{"_csrf" "from-form"}})
(assert (= "from-form" (csrf/presented with-field cfg)))
(def with-header @{:method :post :headers @{"x-csrf-token" "from-header"}})
(assert (= "from-header" (csrf/presented with-header cfg)))
(assert (nil? (csrf/presented @{:method :post :headers @{} :query @{"_csrf" "no"}} cfg))
        "a token in the query string is ignored: query strings end up in logs and referrers")

# -- the binding ---------------------------------------------------------

(assert (= "xyz" (csrf/binding-of (req :post "void-csrf=xyz") cfg))
        "the token is bound to the cookie this module sets")
(assert (nil? (csrf/binding-of (req :post "void-session=abc") cfg))
        "and not to the session id: the page that creates the session is usually the page that carries the form, and at that moment the id does not exist yet")
(assert (= "xyz" (csrf/binding-of (req :post "void-session=abc; void-csrf=xyz") cfg)))
(assert (nil? (csrf/binding-of (req :post) cfg)))

# -- markup --------------------------------------------------------------

(def page (req :get "void-csrf=abc"))
(def field (csrf/field-markup page cfg))
(assert (= :input (first field)))
(assert (= "_csrf" (get-in field [1 :name])))
(assert (csrf/verify (get-in field [1 :value]) "abc"))
(assert (= (get-in field [1 :value]) (get-in (csrf/field-markup page cfg) [1 :value]))
        "one token per request, however many forms the page has")

(def tags (csrf/meta-markup page cfg))
(assert (= 2 (length tags)))
(assert (= "csrf-token" (get-in tags [0 1 :name])))
(def hx (csrf/hx-headers page cfg))
(assert (string/find "x-csrf-token" (get hx :hx-headers:inherited "")))
(assert (nil? (get hx :hx-headers))
        "htmx 4 inherits by name only — a bare hx-headers on <body> would
         cover <body>'s own requests and nothing else")

(print "csrf-test ok")
