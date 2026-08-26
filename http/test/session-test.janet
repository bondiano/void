(import ../test-support/paths)
(import void/http/session :as session)
(import void/http/ring :as ring)

# -- sid -----------------------------------------------------------------

(def a (session/sid))
(assert (= 32 (length a)))
(assert (not= a (session/sid)) "ids are random")
(assert (peg/match '(* (32 :h) -1) a) "hex encoded")

# -- memory store --------------------------------------------------------

(def store (session/memory-store))
(assert (nil? ((store :load) "missing")))
((store :save) "s1" @{:user 7} 60)
(assert (deep= @{:user 7} ((store :load) "s1")))
((store :delete) "s1")
(assert (nil? ((store :load) "s1")))

((store :save) "gone" @{:x 1} -1)   # already expired
(assert (nil? ((store :load) "gone")) "expired entry dies on load")
((store :save) "gone2" @{:x 1} -1)
((store :sweep))
(assert (nil? (get (store :entries) "gone2")) "sweep removes expired entries")

# -- middleware ----------------------------------------------------------

(defn- run [handler &opt cookie]
  (def h (session/wrap-session handler {:store store :ttl 60}))
  (def req @{:headers (if cookie @{"cookie" (string "void-session=" cookie)} @{})})
  [(h req) req])

# anonymous request that never touches the session: no cookie, no save
(def [resp _] (run (fn [req] (ring/response 200 "ok"))))
(assert (nil? (get-in resp [:headers "set-cookie"]))
        "untouched session sets no cookie")

# handler writes to the session: saved + cookie issued
(def [resp2 _] (run (fn [req] (put (req :session) :user 42) (ring/response 200))))
(def cookie-hdr (get-in resp2 [:headers "set-cookie"]))
(assert cookie-hdr "first save sets the cookie")
(def sid2 (first (peg/match '(* "void-session=" '(32 :h)) cookie-hdr)))
(assert sid2 "cookie carries the id")
(assert (string/find "HttpOnly" cookie-hdr) "default cookie attrs applied")
(assert (= 42 (get ((store :load) sid2) :user)) "data landed in the store")

# returning request: loaded, mutated, saved under the same id, no new cookie
(def [resp3 req3] (run (fn [req]
                         (assert (= 42 (get-in req [:session :user])))
                         (put (req :session) :n 1)
                         (ring/response 200))
                       sid2))
(assert (nil? (get-in resp3 [:headers "set-cookie"])) "existing session: no new cookie")
(assert (= 1 (get ((store :load) sid2) :n)) "mutation persisted")

# a client-presented id unknown to the store is never adopted
(def [resp4 _] (run (fn [req] (put (req :session) :fresh true) (ring/response 200))
                    "deadbeefdeadbeefdeadbeefdeadbeef"))
(def new-cookie (get-in resp4 [:headers "set-cookie"]))
(assert new-cookie)
(assert (not (string/find "deadbeefdeadbeefdeadbeefdeadbeef" new-cookie))
        "unknown id is replaced, not adopted")

# response-level replacement
(def [_ _] (run (fn [req] (merge-into (ring/response 200) {:session @{:v 2}}))
                sid2))
(assert (deep= @{:v 2} ((store :load) sid2)) "resp :session replaces the data")

# destroy
(def [resp6 _] (run (fn [req] (merge-into (ring/response 200) {:session :delete}))
                    sid2))
(assert (nil? ((store :load) sid2)) "session destroyed in the store")
(assert (string/find "Max-Age=0" (get-in resp6 [:headers "set-cookie"]))
        "cookie expired on the client")

(print "session-test ok")
