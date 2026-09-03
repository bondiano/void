# test/inject over the :http/kernel component: full-stack in-memory
# requests with zero sockets — kernel-only start (no port), request sugar,
# wire-serialized :raw bytes, cookie jar across a session flow, SSE
# frames, :raw request mode through the server's parser, and the
# :on-response lifecycle stage firing on the inject path exactly as it
# does on the socket path.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/test :as test)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)

(def seen-on-response @[])

(defn hello [req] (ring/text 200 "hello"))

(defn whoami [req]
  (put (req :session) :n (inc (get (req :session) :n 0)))
  (ring/text 200 (string "visit " (get-in req [:session :n]))))

(defn echo-json [req]
  {:status 200
   :headers @{"content-type" "application/json"}
   :body (string "{\"got\":\"" (get-in req [:parsed-body "title"] "?") "\"}")})

(defn events [req]
  (ring/sse (coro
              (yield {:event "tick" :data "one"})
              (yield {:data "two"}))))

(def app-routes
  (router/routes {}
    (router/GET "/" 'hello {:name :hello})
    (router/GET "/whoami" 'whoami {:name :whoami})
    (router/POST "/echo" 'echo-json {:name :echo})
    (router/GET "/events" 'events {:name :events})))

(def app
  (plugin/manifest 'test/inject-app
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/inject-app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]
     :void.http/hook [{:stage :on-response :name :test/spy
                       :fn (fn [req resp]
                             (array/push seen-on-response
                                         [(req :path) (resp :status)]))}]
     :void.http/body-codec [{:name :test/json
                             :content-type "application/json"
                             # a poor man's {"title":"x"} parse
                             :decode (fn [b]
                                       (def s (string b))
                                       (def key "\"title\":\"")
                                       (if-let [i (string/find key s)]
                                         (let [start (+ i (length key))
                                               end (or (string/find "\"" s start) start)]
                                           @{"title" (string/slice s start end)})
                                         @{}))}]}))

(test/with-http [c {:plugins ["void/http/init" app]
                    :config {:env @{}
                             :cli {:http {:access-log false
                                          :session {:enabled true}}}}}]

  # no port is open: the server component is not even in the graph
  (assert (nil? (get-in (c :boot) [:system :instances :http/server]))
          "kernel-only start leaves the server out")
  (assert (get-in (c :boot) [:system :instances :http/kernel]))

  # -- basic request + wire-serialized bytes -----------------------------
  (def r (test/inject c {:uri "/"}))
  (assert (= 200 (r :status)))
  (assert (= "hello" (test/text r)))
  (assert (string/has-prefix? "HTTP/1.1 200" (r :raw))
          ":raw carries the exact wire bytes")
  (assert (string/find "content-length: 5" (string/ascii-lower (r :raw))))

  # the :on-response stage fired on the inject path
  (assert (deep= @[["/" 200]] seen-on-response))

  # -- cookie jar: the session survives across injects -------------------
  (def v1 (test/inject c {:uri "/whoami"}))
  (assert (= "visit 1" (test/text v1)))
  (assert (get-in v1 [:headers "set-cookie"]) "session cookie set")
  (def v2 (test/inject c {:uri "/whoami"}))
  (assert (= "visit 2" (test/text v2))
          "the jar carried the session cookie back")

  # -- :json sugar + body codec + test/json ------------------------------
  (def j (test/inject c {:uri "/echo" :json {:title "x"}}))
  (assert (= 200 (j :status)))
  (assert (= "x" ((test/json j) :got)))

  # -- SSE: frames drained by the wire serializer ------------------------
  (def ev (test/inject c {:uri "/events"}))
  (def frames (test/sse-events ev))
  (assert (= 2 (length frames)) (string/format "%j" frames))
  (assert (= "tick" (get-in frames [0 :event])))
  (assert (= "one" (get-in frames [0 :data])))
  (assert (= "two" (get-in frames [1 :data])))

  # -- :raw request mode: the server's own parser ------------------------
  (def rr (test/inject c {:raw "GET /?q=1 HTTP/1.1\r\nhost: t\r\n\r\n"}))
  (assert (= 200 (rr :status)))
  (assert (= "hello" (test/text rr)))
  (def bad (protect (test/inject c {:raw "NOT HTTP\r\n\r\n"})))
  (assert (not (first bad)) "a malformed raw request throws"))

(print "inject-test: ok")
