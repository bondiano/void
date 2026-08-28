(import ../test-support/paths)
(import void/security/csp :as csp)

(assert (= "default-src 'self'" (csp/render {:default-src [:self]})))
(assert (= "script-src 'self' https://cdn.example.com"
           (csp/render {:script-src [:self "https://cdn.example.com"]}))
        "keywords are the quoted sources, strings are hosts")
(assert (= "frame-ancestors 'none'" (csp/render {:frame-ancestors [:none]})))
(assert (= "upgrade-insecure-requests" (csp/render {:upgrade-insecure-requests true}))
        "a directive without sources is a bare word")
(assert (= "" (csp/render {:upgrade-insecure-requests false})))
(assert (= "" (csp/render {:script-src []})) "an empty source list emits nothing")

(assert (= "base-uri 'self'; default-src 'self'"
           (csp/render {:default-src [:self] :base-uri [:self]}))
        "directives are emitted in a stable order — two processes must produce the same header")

# -- nonces --------------------------------------------------------------

(assert (not (csp/needs-nonce? csp/defaults)) "the default policy uses no nonce")
(assert (csp/needs-nonce? {:script-src [:self :nonce]}))
(assert (= "script-src 'self' 'nonce-abc'" (csp/render {:script-src [:self :nonce]} "abc")))
(assert (= "script-src 'self'" (csp/render {:script-src [:self :nonce]}))
        "without a nonce the source drops out rather than emitting a broken one")

# -- what is refused -----------------------------------------------------

(each [bad reason]
  [[{:scripts-src [:self]} "a misspelled directive — browsers ignore unknown ones, which is why this cannot be silent"]
   [{:default-src [:selfish]} "a keyword that is not a known source"]
   [{:default-src "self"} "sources that are not a list"]
   [{:upgrade-insecure-requests "yes"} "a boolean directive with a string"]]
  (def [ok] (protect (csp/validate bad)))
  (assert (not ok) reason))

(assert (csp/validate csp/defaults) "and the default policy is valid")
(assert (csp/validate {:script-src [:self :nonce :strict-dynamic] :report-uri ["/csp"]}))

(assert (= "content-security-policy" (csp/header-name false)))
(assert (= "content-security-policy-report-only" (csp/header-name true)))

(print "csp-test ok")
