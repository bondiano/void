(import ../test-support/paths)
(import spork/json)
(import void/core/schema :as schema)
(import void/rest/problem :as problem)

# -- json pointers -------------------------------------------------------

(assert (= "" (problem/pointer [])))
(assert (= "/tags/3" (problem/pointer [:tags 3])))
(assert (= "/a~1b/x~0y" (problem/pointer ["a/b" "x~y"])))

# -- bare problems -------------------------------------------------------

(def resp (problem/response 404))
(assert (= 404 (resp :status)))
(assert (= "application/problem+json" (get-in resp [:headers "content-type"])))
(def parsed (json/decode (resp :body) true))
(assert (= "about:blank" (parsed :type)))
(assert (= "Not Found" (parsed :title)))
(assert (= 404 (parsed :status)))

# extensions and standard-member overrides
(def rich (json/decode ((problem/response 403 @{"detail" "no" "balance" 30}) :body) true))
(assert (= "no" (rich :detail)))
(assert (= 30 (rich :balance)))

# -- validation problems -------------------------------------------------

(def check (schema/check {:age [:int {:min 18}]} {:age 3}))
(def vresp (problem/validation 422 :body (check :errors)))
(assert (= 422 (vresp :status)))
(def vbody (json/decode (vresp :body) true))
(assert (= "invalid request body" (vbody :detail)))
(assert (= 1 (length (vbody :errors))))
(def e (first (vbody :errors)))
(assert (= "/age" (e :pointer)))
(assert (= "body" (e :in)))
(assert (string/find "at least" (e :detail)))

# -- from-error ----------------------------------------------------------

# an abort keeps status, message and problem extensions
(def aborted
  (json/decode
    ((problem/from-error {:http/status 409 :message "already shipped"
                          :problem @{"order" 42}}
                         {:status 409 :dev false})
     :body)
    true))
(assert (= "already shipped" (aborted :detail)))
(assert (= 42 (aborted :order)))
(assert (= 409 (aborted :status)))

# a prod 500 hides details
(def prod500
  (json/decode
    ((problem/from-error "kaboom secret" {:status 500 :dev false}) :body)
    true))
(assert (nil? (prod500 :detail)))
(assert (= "Internal Server Error" (prod500 :title)))

# a dev 500 shows them
(def dev500
  (json/decode
    ((problem/from-error "kaboom secret" {:status 500 :dev true}) :body)
    true))
(assert (= "kaboom secret" (dev500 :detail)))

(print "problem-test: ok")
