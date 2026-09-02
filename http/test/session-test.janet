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

# -- rotation (session fixation, ADR-0023 §8) ----------------------------

((store :save) "fixated0fixated0fixated0fixated0" @{:visits 3} 60)

(def [resp7 _] (run (fn [req]
                      (session/rotate! req)
                      (put (req :session) :user 9)
                      (ring/response 200))
                    "fixated0fixated0fixated0fixated0"))
(def rotated-cookie (get-in resp7 [:headers "set-cookie"]))
(assert rotated-cookie "a rotated session issues a new cookie")
(assert (not (string/find "fixated0fixated0fixated0fixated0" rotated-cookie))
        "and the new id is not the old one — an id that survives a login is session fixation")
(assert (nil? ((store :load) "fixated0fixated0fixated0fixated0"))
        "the old entry is gone from the store, or the fixated id still works")

(def new-sid (first (peg/match '(* "void-session=" (<- (32 :h))) rotated-cookie)))
(assert (deep= @{:visits 3 :user 9} ((store :load) new-sid))
        "the data survives the rotation — only the id changes")

# the response marker is the same instruction by another spelling
((store :save) "second0second0second0second0abcd" @{:v 1} 60)
(def [resp8 _] (run (fn [req] (merge-into (ring/response 200) {:session :rotate}))
                    "second0second0second0second0abcd"))
(assert (nil? ((store :load) "second0second0second0second0abcd")))
(def sid8 (first (peg/match '(* "void-session=" (<- (32 :h)))
                            (get-in resp8 [:headers "set-cookie"]))))
(assert (deep= @{:v 1} ((store :load) sid8)))
(assert (not (dictionary? :rotate)) "the marker is a keyword, so it cannot be mistaken for session data")

# rotating a request that has no session yet is not an error: the id is
# fresh anyway, which is what a login on an anonymous visit does
(def [resp9 _] (run (fn [req]
                      (session/rotate! req)
                      (put (req :session) :user 1)
                      (ring/response 200))))
(assert (get-in resp9 [:headers "set-cookie"]))

# -- :cookie-opts shape the cookie (H3: Secure must be reachable) --------

(def secure-h
  (session/wrap-session
    (fn [req] (put (req :session) :u 1) (ring/response 200))
    {:store store :ttl 60
     :cookie-opts {:secure true :same-site :strict}}))
(def secure-resp (secure-h @{:headers @{}}))
(def secure-cookie (get-in secure-resp [:headers "set-cookie"]))
(assert (string/find "Secure" secure-cookie)
        ":cookie-opts can turn Secure on — a session cookie a browser also
        sends over plain http is a session to steal")
(assert (string/find "SameSite=Strict" secure-cookie)
        "and tighten SameSite")
(assert (string/find "HttpOnly" secure-cookie)
        "while the defaults underneath the merge survive")
(assert (string/find "Path=/" secure-cookie))

(print "session-test ok")
