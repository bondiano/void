### void/security/csrf — one token, always signed.
###
### **When it applies.** Not "every unsafe method" — that breaks every
### JSON API with a bearer token, and the `:restrict` merge on
### `:void.security/csrf` (frozen in v1: true wins) means a group could
### never switch it back off. The rule is the model of the attack
### instead: a request is checked when it is **unsafe** *and* its
### credential rode on a **cookie** — a session cookie, or an identity
### a cookie-reading strategy established (`(id :cookie)`, which is why
### void/auth records it). A request that authenticates with
### `Authorization: Bearer` cannot be forged by another origin, because
### the browser will not attach that header for them. `:void.security/csrf
### true` on a route tightens this to "always", which is what the
### frozen merge strategy already means.
###
### **The token.** `<nonce>.<issued-at>.<mac>`, where the MAC is
### HMAC-SHA256 over the three parts plus a **binding**: the value of a
### cookie this module sets. One format, one verification path, one
### binding (on why there is not a second, unsigned kind).
###
### The binding is deliberately *not* the session id, although that
### would be a stronger tie. A page is very often rendered by the
### request that creates the session — the form and the `Set-Cookie`
### leave together — so at the moment the token is minted the session
### id does not exist yet, and a token bound to it would be refused on
### submission by the very flow it exists to protect. The cookie this
### module sets is there on the first response and does not change.
###
### The residual risk of binding to a cookie is *cookie tossing*: a
### subdomain that can write cookies for the parent domain could plant
### a matching pair. Signing does not fix that on its own — the fix is
### the `__Host-` cookie prefix, which browsers refuse to accept from a
### subdomain or without `Secure` and `Path=/`. Set
### `[:security :csrf :cookie]` to `"__Host-void-csrf"` in any
### deployment that has subdomains it does not fully control; it is not
### the default only because `__Host-` requires https and `void dev`
### does not have it.
###
### Because the MAC carries its own timestamp, verification touches no
### storage: it recomputes and compares in constant time, and refuses
### anything older than `:max-age`.
###
### **Where it arrives from.** A hidden form field (`_csrf`, spliced
### into every non-GET form through the `(dyn :void.html/csrf)` slot
### void/html has been waiting with since wave 1), or the
### `x-csrf-token` header (what `(security/htmx-meta)` arranges for
### htmx and what a fetch() sets), and nothing else: a token in a query
### string ends up in logs and referrers.
###
### **Login CSRF is the deliberate hole in the cookie-borne rule, and
### routes must close it themselves.** A `POST /login` from a visitor
### with no cookie at all is not checked by the rule above — there is
### no credential of theirs to ride. What that leaves open is *login
### CSRF*: another origin submits the attacker's credentials, the
### victim's browser is signed into the attacker's account, and
### whatever the victim then does there (a saved card, an uploaded
### document) lands where the attacker can read it. The fix is
### `:void.security/csrf true` on the login, registration and
### password-reset routes — the flag that means "always check,
### cookie or not". The `void make auth` generators stamp it on every
### route they write; a hand-written login form owes itself the same
### line.

(import void/crypto :as crypto)
(import void/http/ring :as ring)
(import ./secret :as secret)

(def defaults
  "Defaults of the [:security :csrf] slice."
  {:enabled true
   :field "_csrf"
   :header "x-csrf-token"
   :cookie "void-csrf"
   # the same name [:http :session :cookie] defaults to. The boot hook
   # in ./init keeps them one value: left on this default it follows
   # http's setting, and set to anything else that disagrees with it
   # the boot refuses — a renamed session cookie the CSRF rule does
   # not know about would silently stop the check on every
   # anonymous-session flow
   :session-cookie "void-session"
   # eight hours: longer than a form sits open, shorter than a session
   :max-age 28800
   :safe-methods [:get :head :options :trace]
   :cookie-opts {:path "/" :same-site :lax :http-only false}})

(defn- now [] (os/time))

(defn issue
  ``A token bound to `binding`. The binding is whatever identifies the
  browser session — a session id, or the value of the CSRF cookie —
  and it is *not* in the token: it is in the signature, so a token
  minted for one browser does not verify for another.``
  [binding &opt at]
  (default at (now))
  (def nonce (crypto/token 16))
  (def stamp (string at))
  (def mac (secret/sign (string nonce "." stamp "." binding)))
  (string nonce "." stamp "." (crypto/base64url mac)))

(defn verify
  "Is this a token this process (or a process with one of its keys)
  issued for this binding, and not too old?"
  [token binding &opt opts]
  (default opts {})
  (def max-age (get opts :max-age (defaults :max-age)))
  (def at (get opts :now (now)))
  (and (bytes? token)
       (truthy? binding)
       (let [parts (string/split "." (string token))]
         (and (= 3 (length parts))
              (let [[nonce stamp mac] parts
                    issued (scan-number stamp)]
                (and issued
                     (<= issued (+ at 60))          # not from the future
                     (>= issued (- at max-age))     # and not stale
                     (let [[ok raw] (protect (crypto/base64url-decode mac))]
                       (and ok
                            (secret/valid? (string nonce "." stamp "." binding) raw)))))))))

(defn binding-of
  ``What this request's token is bound to: the value of the CSRF
  cookie. nil when the browser has not been given one yet — the
  middleware then mints one and sets it on this response, so the token
  it hands out and the cookie it sets agree.``
  [req cfg]
  (get (ring/cookies req) (get cfg :cookie (defaults :cookie))))

(defn safe-method?
  "Is this method one that is not supposed to change anything?"
  [method cfg]
  (truthy? (index-of method (get cfg :safe-methods (defaults :safe-methods)))))

(defn cookie-borne?
  ``Did this request's credential arrive on a cookie? True when an
  identity says so (`void/auth` sets `:cookie` on the identity it
  built — the strategy is the only thing that knows), or when the
  request carries a session cookie at all.``
  [req cfg]
  (def id (get req :void.auth/identity))
  (or (truthy? (and id (get id :cookie)))
      (truthy? (get (ring/cookies req)
                    (get cfg :session-cookie (defaults :session-cookie))))))

(defn applies?
  ``Should this request be checked? Unsafe method, and either a
  cookie-borne credential or a route that asked for the check
  unconditionally (`:void.security/csrf true`).``
  [req rmeta cfg]
  (and (get cfg :enabled true)
       (not (safe-method? (get req :method :get) cfg))
       (or (get rmeta :void.security/csrf false)
           (cookie-borne? req cfg))))

(defn presented
  "The token the request carries: the form field, then the header."
  [req cfg]
  (or (get-in req [:form (get cfg :field (defaults :field))])
      (get-in req [:parsed-body (get cfg :field (defaults :field))])
      (ring/request-header req (get cfg :header (defaults :header)))))

(defn token-for
  ``The token to hand this request's page, minted once per request and
  memoized: a page with three forms should carry one token, not three,
  and every one of them must verify.``
  [req cfg]
  (or (get req :void.security/token)
      (let [binding (or (binding-of req cfg) (get req :void.security/fresh-binding))
            token (issue binding)]
        (put req :void.security/token token)
        token)))

(defn field-markup
  ``The hidden input, as hiccup. This is what the `(dyn :void.html/csrf)`
  slot splices into every non-GET form (void/html has had the slot
  since wave 1 and rendered nothing until now).``
  [req cfg]
  [:input {:type "hidden"
           :name (get cfg :field (defaults :field))
           :value (token-for req cfg)}])

(defn meta-markup
  ``The `<meta>` tag plus the `hx-headers` attribute htmx needs, as
  hiccup:

      (html/page {:head (security/meta-markup req)} ...)

  htmx 4 inherits an attribute only where the name says so, so what
  goes on `<body>` is `hx-headers:inherited` (./hx-headers) — see
  htmx 4.``
  [req cfg]
  (def token (token-for req cfg))
  (def header (get cfg :header (defaults :header)))
  [[:meta {:name "csrf-token" :content token}]
   [:meta {:name "csrf-header" :content header}]])

(defn hx-headers
  ``The attribute map to merge onto `<body>` so every htmx request
  carries the token.

  The name carries htmx 4's `:inherited` suffix, and it has to: since
  4.0 an attribute applies to the element it sits on and no further
, and a token that reached only `<body>`'s own requests
  would leave every other element's POST to be refused.``
  [req cfg]
  {:hx-headers:inherited (string/format `{"%s": "%s"}`
                                        (get cfg :header (defaults :header))
                                        (token-for req cfg))})
