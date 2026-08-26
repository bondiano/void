(import ../test-support/paths)
(import void/http/ring :as ring)
(import void/http/negotiate :as negotiate)

# -- responses -----------------------------------------------------------

(def r (ring/response 200 "hi" {"x-a" "1"}))
(assert (= 200 (r :status)))
(assert (= "hi" (r :body)))
(assert (= "1" (get-in r [:headers "x-a"])))

(ring/header r "x-a" "2")
(assert (= "2" (get-in r [:headers "x-a"])) "header replaces")
(ring/header-add r "x-a" "3")
(assert (deep= @["2" "3"] (get-in r [:headers "x-a"])) "header-add accumulates")

(assert (= "text/plain; charset=utf-8"
           (get-in (ring/text 404 "no") [:headers "content-type"])))
(assert (= 302 ((ring/redirect "/x") :status)))
(assert (= "/x" (get-in (ring/redirect "/x") [:headers "location"])))
(assert (= 301 ((ring/redirect "/x" 301) :status)))

# -- request access ------------------------------------------------------

(def req @{:headers @{"cookie" "a=1; b=2" "x-dup" @["p" "q"]}})
(assert (= "p" (ring/request-header req "x-dup")) "first of a repeated header")
(assert (= "1" ((ring/cookies req) "a")))
(assert (= "2" ((ring/cookies req) "b")))
(assert (= (req :cookies) (ring/cookies req)) "cookies are memoized")

# -- set-cookie ----------------------------------------------------------

(def c (ring/cookie-str :sid "v 1"
                        {:path "/" :max-age 60 :secure true :http-only true
                         :same-site :lax}))
(assert (= "sid=v%201; Path=/; Max-Age=60; Secure; HttpOnly; SameSite=Lax" c)
        "cookie attributes render in order, value url-encoded")

(def resp (ring/response 200))
(ring/set-cookie resp :a "1")
(ring/set-cookie resp :b "2" {:path "/"})
(assert (deep= @["a=1" "b=2; Path=/"] (get-in resp [:headers "set-cookie"]))
        "multiple cookies accumulate")

(def del (ring/delete-cookie (ring/response 200) :sid {:path "/"}))
(assert (string/find "Max-Age=0" (first (flatten [(get-in del [:headers "set-cookie"])])))
        "delete-cookie expires")

(assert (not (first (protect (ring/cookie-str :a "b" {:same-site :bogus}))))
        "bad same-site is an error")

# -- sse -----------------------------------------------------------------

(assert (= "data: hi\n\n" (ring/sse-event "hi")))
(assert (= "id: 1\nevent: tick\nretry: 500\ndata: a\ndata: b\n\n"
           (ring/sse-event {:id 1 :event "tick" :retry 500 :data "a\nb"})))

(def stream (ring/sse (coro (yield "one") (yield {:data "two"}))))
(assert (= "text/event-stream" (get-in stream [:headers "content-type"])))
(assert (fiber? (stream :body)))
(def events (values (seq [e :in (stream :body)] e)))
(assert (deep= @["data: one\n\n" "data: two\n\n"] events)
        "fiber body yields formatted events")

(def listed (ring/sse ["a" "b"]))
(assert (deep= @["data: a\n\n" "data: b\n\n"] (listed :body)))

# -- negotiate -----------------------------------------------------------

(def acc "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
(assert (= "text/html" (negotiate/best acc ["application/json" "text/html"])))
(assert (= "application/json" (negotiate/best acc ["application/json"]))
        "*/* fallback accepts anything")
(assert (= "text/html" (negotiate/best nil ["text/html" "application/json"]))
        "no header -> first offer")
(assert (nil? (negotiate/best "application/json" ["text/html"]))
        "no acceptable offer -> nil")
(assert (nil? (negotiate/best "text/*;q=0, */*" ["text/html"]))
        "q=0 excludes the subtree")
(assert (= "text/plain" (negotiate/best "text/*" ["text/plain" "image/png"]))
        "type wildcard matches the subtree")

(assert (negotiate/accepts? "text/html" "text/html"))
(assert (negotiate/accepts? "text/*" "text/plain"))
(assert (not (negotiate/accepts? "text/html" "application/json")))
(assert (negotiate/accepts? nil "application/json") "no header accepts all")

(assert (= "application/json"
           (negotiate/negotiate @{:headers @{"accept" "application/json"}}
                                ["text/html" "application/json"]))
        "negotiate reads the request table")

(print "ring-test ok")
