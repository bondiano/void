### void/security/cors — cross-origin requests, answered at the edge.
###
### CORS lives with the security headers for one structural reason: a
### **preflight** is an `OPTIONS` request to a path that usually has no
### `OPTIONS` route, so a middleware attached to a route chain would
### never see it — the kernel would answer 405 before anything got a
### say. At the edge it is answered before routing is even attempted.
###
### The allowlist is exact origins (or a predicate, for the deployment
### with a hundred tenant domains). `*` is supported and **refused
### together with `:credentials true`** at boot: the combination is
### rejected by every browser anyway, and finding that out from a
### console message in a customer's browser is a worse afternoon than
### finding it out at startup.

(def defaults
  "Defaults of the [:security :cors] slice — off until configured."
  {:enabled false
   :origins []
   :methods [:get :post :put :patch :delete :options]
   :headers ["content-type" "authorization" "x-csrf-token" "x-requested-with"]
   :expose []
   :credentials false
   :max-age 600})

(defn validate
  "Check a CORS configuration; throws on the combination browsers
  refuse."
  [cfg]
  (when (and (get cfg :credentials)
             (truthy? (index-of "*" (map string (get cfg :origins [])))))
    (error (string "[:security :cors] has :credentials true and \"*\" in :origins. "
                   "No browser accepts that combination — list the origins that "
                   "may send credentials")))
  cfg)

(defn origin-allowed?
  "Is this Origin in the allowlist? `:origins` may hold exact strings,
  \"*\", or a predicate function."
  [origin cfg]
  (and origin
       (truthy?
         (some (fn [entry]
                 (cond
                   (function? entry) (entry origin)
                   (= "*" (string entry)) true
                   (= (string entry) origin)))
               (get cfg :origins [])))))

(defn- methods-str [cfg]
  (string/join (map |(string/ascii-upper (string $)) (get cfg :methods [])) ", "))

(defn preflight?
  "Is this the OPTIONS request a browser sends before a cross-origin
  call?"
  [req]
  (and (= :options (get req :method))
       (truthy? (get-in req [:headers "origin"]))
       (truthy? (get-in req [:headers "access-control-request-method"]))))

(defn- allow-headers [req cfg]
  (def asked (get-in req [:headers "access-control-request-headers"]))
  (if (and asked (empty? (get cfg :headers [])))
    (string asked)
    (string/join (map string (get cfg :headers [])) ", ")))

(defn decorate!
  ``Add the response half of CORS to an ordinary (non-preflight)
  response, when the Origin is allowed. `Vary: Origin` goes on
  whatever the answer is — without it a cache hands one origin's
  response to another.``
  [req resp cfg]
  (def origin (get-in req [:headers "origin"]))
  (when (and (dictionary? resp) origin (get cfg :enabled))
    (unless (resp :headers) (put resp :headers @{}))
    (def hs (resp :headers))
    (put hs "vary" (if-let [v (get hs "vary")] (string v ", Origin") "Origin"))
    (when (origin-allowed? origin cfg)
      # the origin is echoed rather than "*" whenever credentials are
      # allowed, because "*" and credentials cannot be combined
      (put hs "access-control-allow-origin"
           (if (get cfg :credentials) origin
             (if (truthy? (index-of "*" (map string (get cfg :origins [])))) "*" origin)))
      (when (get cfg :credentials)
        (put hs "access-control-allow-credentials" "true"))
      (unless (empty? (get cfg :expose []))
        (put hs "access-control-expose-headers"
             (string/join (map string (get cfg :expose [])) ", ")))))
  resp)

(defn preflight-response
  ``The answer to a preflight: 204 with the negotiated headers, or 403
  when the origin is not allowed. Either way it is produced without
  touching the router — the path may have no OPTIONS route, and
  usually does not.``
  [req cfg]
  (def origin (get-in req [:headers "origin"]))
  (if (origin-allowed? origin cfg)
    (let [hs @{"access-control-allow-origin"
               (if (get cfg :credentials) origin
                 (if (truthy? (index-of "*" (map string (get cfg :origins [])))) "*" origin))
               "access-control-allow-methods" (methods-str cfg)
               "access-control-allow-headers" (allow-headers req cfg)
               "access-control-max-age" (string (get cfg :max-age 600))
               "vary" "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"}]
      # `put` rather than a splice: a table literal takes a fixed number
      # of entries, and `;` is a call-site construct
      (when (get cfg :credentials)
        (put hs "access-control-allow-credentials" "true"))
      @{:status 204 :body nil :headers hs})
    @{:status 403
      :body "cross-origin request not allowed"
      :headers @{"content-type" "text/plain; charset=utf-8"
                 "vary" "Origin"}}))
