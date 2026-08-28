(import ../test-support/paths)
(import void/security/headers :as headers)

(def hs (headers/compute {}))
(assert (= "nosniff" (hs "x-content-type-options")))
(assert (= "DENY" (hs "x-frame-options")))
(assert (string/find "strict-origin" (hs "referrer-policy")))
(assert (nil? (hs "strict-transport-security"))
        "HSTS is off unless configured — it is a promise a browser remembers for months")

(assert (empty? (headers/compute {:enabled false})))

(def with-hsts (headers/compute {:hsts {:max-age 100}}))
(assert (= "max-age=100" (with-hsts "strict-transport-security")))
(assert (= "max-age=100; includeSubDomains; preload"
           ((headers/compute {:hsts {:max-age 100 :include-subdomains true :preload true}})
            "strict-transport-security")))

(def custom (headers/compute {:x-frame-options "SAMEORIGIN"
                              :extra {:x-app "void"}}))
(assert (= "SAMEORIGIN" (custom "x-frame-options")) "a configured value replaces the default")
(assert (= "void" (custom "x-app")) "and :extra carries anything else")
(assert (nil? ((headers/compute {:referrer-policy false}) "referrer-policy"))
        "a header set to false is not sent at all — false rather than nil, because janet drops a nil value from a struct literal and the merge would keep the default")

# -- applying ------------------------------------------------------------

(def resp @{:status 200 :headers @{"x-frame-options" "ALLOWALL"}})
(headers/apply! resp hs)
(assert (= "ALLOWALL" (get-in resp [:headers "x-frame-options"]))
        "a header the handler set is left alone — an embeddable page had a reason")
(assert (= "nosniff" (get-in resp [:headers "x-content-type-options"])))

(def bare @{:status 404})
(headers/apply! bare hs)
(assert (= "nosniff" (get-in bare [:headers "x-content-type-options"]))
        "a response with no header table at all gets one")

(print "headers-test ok")
