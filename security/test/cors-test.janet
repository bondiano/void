(import ../test-support/paths)
(import void/security/cors :as cors)

(def cfg (merge cors/defaults {:enabled true :origins ["https://app.example" "https://admin.example"]}))

# -- what a preflight is -------------------------------------------------

(def pre @{:method :options
           :headers @{"origin" "https://app.example"
                      "access-control-request-method" "POST"
                      "access-control-request-headers" "content-type, x-csrf-token"}})
(assert (cors/preflight? pre))
(assert (not (cors/preflight? @{:method :options :headers @{}}))
        "an OPTIONS without the preflight headers is an ordinary OPTIONS")
(assert (not (cors/preflight? @{:method :get :headers @{"origin" "https://app.example"
                                                        "access-control-request-method" "POST"}})))

(def answer (cors/preflight-response pre cfg))
(assert (= 204 (answer :status)))
(assert (= "https://app.example" (get-in answer [:headers "access-control-allow-origin"])))
(assert (string/find "POST" (get-in answer [:headers "access-control-allow-methods"])))
(assert (string/find "x-csrf-token" (get-in answer [:headers "access-control-allow-headers"])))
(assert (= "600" (get-in answer [:headers "access-control-max-age"])))
(assert (nil? (get-in answer [:headers "access-control-allow-credentials"]))
        "credentials are not offered unless they are configured")

(def refused (cors/preflight-response
               @{:method :options :headers @{"origin" "https://evil.example"
                                             "access-control-request-method" "POST"}}
               cfg))
(assert (= 403 (refused :status)) "an origin outside the allowlist is refused")
(assert (nil? (get-in refused [:headers "access-control-allow-origin"])))

# -- ordinary responses --------------------------------------------------

(defn- decorate [origin conf]
  (def resp @{:status 200 :headers @{}})
  (cors/decorate! @{:headers @{"origin" origin}} resp conf)
  resp)

(assert (= "https://app.example"
           (get-in (decorate "https://app.example" cfg) [:headers "access-control-allow-origin"])))
(assert (nil? (get-in (decorate "https://evil.example" cfg) [:headers "access-control-allow-origin"]))
        "and an origin that is not allowed simply gets no header")
(assert (= "Origin" (get-in (decorate "https://evil.example" cfg) [:headers "vary"]))
        "Vary: Origin goes on either answer — without it a cache hands one origin's response to another")

(def off (merge cfg {:enabled false}))
(assert (nil? (get-in (decorate "https://app.example" off) [:headers "access-control-allow-origin"])))

# -- credentials and the wildcard ---------------------------------------

(def creds (merge cfg {:credentials true}))
(def with-creds (decorate "https://app.example" creds))
(assert (= "true" (get-in with-creds [:headers "access-control-allow-credentials"])))
(assert (= "https://app.example" (get-in with-creds [:headers "access-control-allow-origin"]))
        "the origin is echoed rather than * — the two cannot be combined")

(def star (merge cors/defaults {:enabled true :origins ["*"]}))
(assert (= "*" (get-in (decorate "https://anything.example" star)
                       [:headers "access-control-allow-origin"])))

(def [ok err] (protect (cors/validate {:credentials true :origins ["*"]})))
(assert (not ok) "* with credentials is refused at boot rather than in somebody's browser console")
(assert (string/find "credentials" (string err)))
(assert (cors/validate creds) "and a real allowlist with credentials is fine")

# -- a predicate allowlist -----------------------------------------------

(def tenants (merge cors/defaults
                    {:enabled true
                     :origins [(fn [origin] (string/has-suffix? ".tenant.example" origin))]}))
(assert (cors/origin-allowed? "https://a.tenant.example" tenants))
(assert (not (cors/origin-allowed? "https://evil.example" tenants)))

(print "cors-test ok")
