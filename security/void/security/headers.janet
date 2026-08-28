### void/security/headers — the response headers a browser needs
### (ADR-0025 §3).
###
### Static values, computed once at boot and stamped on every response
### **at the edge** — the point of application matters more than the
### list: middleware wraps a route's chain, so a 404, a static file and
### a 500 the panic guard rendered would all go out bare, and those are
### the responses where a missing `nosniff` or a missing
### `frame-ancestors` costs the most.
###
### A header the handler already set is left alone. A response that
### deliberately allows framing (an embeddable widget) says so by
### setting the header itself, and this module does not argue.
###
### HSTS is **off unless configured**, and that is not timidity: the
### header is a promise a browser remembers for months, and a framework
### that sends it by default breaks the first developer who opens the
### app over plain http on a shared hostname. `[:security :hsts]` turns
### it on with the numbers the deployment actually wants.

(def defaults
  ``The default header set.

  `x-frame-options` is legacy — `frame-ancestors` in the CSP is the
  modern spelling and both are sent, because the browsers that only
  understand the old one are exactly the ones least likely to be
  patched.

  `referrer-policy` is `strict-origin-when-cross-origin`: the path
  stays inside the origin, the origin still reaches third parties over
  https, and nothing at all leaves over http.

  A header is switched off by setting it to **false** rather than nil:
  janet drops a nil value from a struct literal, so `{:x-frame-options
  nil}` in a config file would merge to nothing at all and leave the
  default in place.``
  {:enabled true
   :x-content-type-options "nosniff"
   :x-frame-options "DENY"
   :referrer-policy "strict-origin-when-cross-origin"
   :cross-origin-opener-policy "same-origin"
   :permissions-policy "geolocation=(), microphone=(), camera=()"
   :x-dns-prefetch-control "off"
   :hsts nil
   :extra {}})

(def- header-keys
  [:x-content-type-options :x-frame-options :referrer-policy
   :cross-origin-opener-policy :permissions-policy :x-dns-prefetch-control])

(defn hsts-value
  ``The Strict-Transport-Security value for `{:max-age :include-subdomains
  :preload}`, or nil when it is not configured.``
  [cfg]
  (when cfg
    (def max-age (get cfg :max-age 31536000))
    (string "max-age=" max-age
            (if (get cfg :include-subdomains) "; includeSubDomains" "")
            (if (get cfg :preload) "; preload" ""))))

(defn compute
  ``The header table for a configuration — name -> value, ready to
  stamp. Built once at boot: these values never depend on the
  request, and recomputing them per response would be the kind of
  cost nobody notices until it is 8% of a benchmark.``
  [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (def out @{})
  (when (get cfg :enabled true)
    (each k header-keys
      (when-let [v (get cfg k)]
        (put out (string k) v)))
    (when-let [hsts (hsts-value (get cfg :hsts))]
      (put out "strict-transport-security" hsts))
    (eachp [k v] (get cfg :extra {})
      (put out (string k) (string v))))
  (freeze out))

(defn apply!
  ``Stamp `headers` onto a response, without overwriting anything the
  handler set: a response that chose its own `x-frame-options` had a
  reason, and this is a floor rather than a policy.``
  [resp headers]
  (when (dictionary? resp)
    # `put` returns the table it was given, not the value, so the
    # obvious `(or (resp :headers) (put resp :headers @{}))` hands back
    # the response itself
    (unless (resp :headers) (put resp :headers @{}))
    (def hs (resp :headers))
    (eachp [name value] headers
      (unless (in hs name) (put hs name value))))
  resp)
