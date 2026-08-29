### The suite that needs a real socket: a booted application with
### websocket routes, and void/ws/client on the other end of them.
### Everything below the handshake — framing, fragmentation, control
### frames, the close handshake, rooms and broadcast — is exercised
### over TCP rather than against a mock, because a websocket that works
### against a mock is a data structure.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/router :as router)
(import void/http/ring :as ring)
(require "void/http/init")
(import void/ws :as ws)
(import void/ws/client :as wsc)
(import void/ws/frame :as frame)
(import void/ws/conn :as conn)

(log/set-level! "void" :error)

# -- the application -----------------------------------------------------

(def events @[])

(defn echo
  "Every message straight back — the smallest possible socket."
  [req]
  (ws/accept req
    {:on-open (fn [c] (array/push events [:open (c :id)]))
     :on-close (fn [c ci] (array/push events [:close (ci :code)]))
     :on-message
     (fn [c msg]
       (array/push events [:message (msg :type) (length (msg :data))])
       (if (= :binary (msg :type))
         (ws/send-binary! c (msg :data))
         (ws/send! c (msg :data))))}))

(defn lobby
  "A room: everything one peer says, every other peer hears."
  [req]
  (ws/accept req
    {:rooms [:lobby]
     :protocols ["chat.v2" "chat.v1"]
     :on-message (fn [c msg] (ws/broadcast! :lobby (msg :data) {:except c}))}))

(defn params
  "The handshake is a routed request like any other: it has params, a
  query and headers, and the socket can see all of them."
  [req]
  (ws/accept req
    {:on-open (fn [c] (ws/send! c (string (get-in req [:params :room]) "/"
                                          (get-in req [:query "as"] "anon"))))}))

(defn boom
  "A handler that throws: the connection must die with 1011 and the
  process must not."
  [req]
  (ws/accept req {:on-message (fn [c msg] (error "handler exploded"))}))

(defn plain
  "An ordinary route, for the refusals."
  [req]
  (ring/text 200 "not a socket"))

(def app-routes
  (router/routes {}
    (router/GET "/echo" 'echo {:name :echo :void.ws/socket true})
    (router/GET "/lobby" 'lobby {:name :lobby :void.ws/socket true})
    (router/GET "/rooms/:room" 'params {:name :params :void.ws/socket true})
    (router/GET "/boom" 'boom {:name :boom :void.ws/socket true})
    (router/GET "/plain" 'plain {:name :plain})))

(def app
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/ws ">=0.0.1"}
    :contributes {:void.http/route-source
                  [{:name :test/app :routes app-routes
                    :env (router/env-ref (curenv))}]}))

(def boot
  (test/start! {:plugins [:void/http :void/ws app]
                :config {:env @{}
                         :cli {:log {:level :error}
                               :http {:port 0 :strict-meta true}
                               :ws {:ping-interval 0.2 :pong-timeout 0.5
                                    :sweep-interval 0.1
                                    :max-message 4096
                                    :max-connections 8}}}}))

(def port (get-in boot [:system :instances :http/server :server :port]))
(assert (pos? port) "the server bound an ephemeral port")

(defn- url [path] (string "ws://127.0.0.1:" port path))

(defn- wait-for
  "Poll a predicate for up to `seconds` — the server side of a socket
  runs in its own fiber, so a test that asserts on it right after
  writing to the wire is asserting on a race."
  [pred &opt seconds message]
  (default seconds 3)
  (def deadline (+ (os/clock :monotonic) seconds))
  (while (and (not (pred)) (< (os/clock :monotonic) deadline))
    (ev/sleep 0.005))
  (assert (pred) (or message "the server never got there"))
  true)

(defer (test/stop! boot 3)

  # -- echo, both framings, and a message bigger than one read -----------

  (def c (wsc/connect (url "/echo")))
  (wsc/send! c "hello")
  (assert (= {:type :text :data "hello"} (wsc/receive c)) "text comes back")
  (wsc/send-binary! c "\x00\x01\xff")
  (assert (= {:type :binary :data "\x00\x01\xff"} (wsc/receive c))
          "binary comes back as binary — the opcode is part of the message")

  (def big (string/repeat "abcdefgh" 400))     # 3200 bytes, one frame
  (wsc/send! c big)
  (assert (= big ((wsc/receive c) :data))
          "a message larger than a single read is reassembled")

  (assert (= [:open (get-in (ws/connections) [0 :id])] (first events))
          ":on-open ran with the connection")

  # -- ping/pong, both directions ----------------------------------------

  (wsc/ping! c "beat")
  # the pong is answered inside receive, so what comes back next is the
  # echo of the message after it
  (wsc/send! c "after-ping")
  (assert (= "after-ping" ((wsc/receive c) :data))
          "a ping is answered without disturbing the message stream")

  (def server-conn (first (ws/connections)))
  (assert (ws/open? server-conn))
  (assert (pos? ((ws/info server-conn) :received)))

  # -- the close handshake -----------------------------------------------

  (wsc/close! c :normal "done")
  (wait-for |(conn/closed? server-conn) 3 "the server saw the close")
  (wait-for |(= [:close 1000] (last events)) 3
            ":on-close got the peer's own code, not a guess")

  # -- the socket is a route: params, query, and the middleware chain -----

  (def p (wsc/connect (url "/rooms/kitchen?as=cook")))
  (assert (= "kitchen/cook" ((wsc/receive p) :data))
          "the handshake request is a routed request, params and all")
  (wsc/close! p)

  # -- subprotocols ------------------------------------------------------

  (def sp (wsc/connect (url "/lobby") {:protocols ["chat.v1" "chat.v2"]}))
  (assert (= "chat.v2" (sp :protocol))
          "the server's preference picked the subprotocol")
  (wsc/close! sp)

  (def [ok err] (protect (wsc/connect (url "/lobby") {:protocols ["mqtt"]})))
  (assert (not ok) "a subprotocol the route does not speak is refused")
  (assert (string/find "400" (string err)) "and refused as HTTP, not as a frame")

  # -- rooms and broadcast -----------------------------------------------

  (def a (wsc/connect (url "/lobby")))
  (def b (wsc/connect (url "/lobby")))
  (def d (wsc/connect (url "/lobby")))
  (wait-for |(= 3 (length (ws/members :lobby))) 3 "three peers in the room")
  (assert (= [:lobby] (ws/room-names)))

  (wsc/send! a "everybody hear this")
  (assert (= "everybody hear this" ((wsc/receive b) :data)))
  (assert (= "everybody hear this" ((wsc/receive d) :data)))

  (assert (= 3 (ws/broadcast! :lobby "from the server"))
          "a server-side broadcast reaches every member and says how many")
  (each peer [a b d]
    (assert (= "from the server" ((wsc/receive peer) :data))))

  # the room is its members: they leave by disconnecting
  (wsc/close! d)
  (wait-for |(= 2 (length (ws/members :lobby))) 3
            "a disconnected peer is out of the room without anyone unregistering it")
  (wsc/close! a)
  (wsc/close! b)

  # -- protocol violations get the code the RFC names --------------------

  (defn- raw-frame
    "Send bytes straight at the server and read the close it earns."
    [bytes]
    (def sock (net/connect "127.0.0.1" (string port)))
    (defer (protect (:close sock))
      (def key "dGhlIHNhbXBsZSBub25jZQ==")
      (:write sock (string "GET /echo HTTP/1.1\r\nHost: t\r\n"
                           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Version: 13\r\n"
                           "Sec-WebSocket-Key: " key "\r\n\r\n"))
      (def buf @"")
      (while (nil? (string/find "\r\n\r\n" buf))
        (unless (net/read sock 4096 buf 2) (break)))
      (def head-end (+ 4 (string/find "\r\n\r\n" buf)))
      (def rest (buffer (string/slice buf head-end)))
      (:write sock bytes)
      (var f nil)
      (def deadline (+ (os/clock :monotonic) 2))
      (while (and (nil? f) (< (os/clock :monotonic) deadline))
        (set f (frame/parse rest 0 {:expect-mask false}))
        (unless f
          (unless (net/read sock 4096 rest 1) (break))))
      (when (and f (= :close (f :opcode)))
        (frame/parse-close (f :payload)))))

  (assert (= 1002 ((raw-frame "\x81\x05hello") :code))
          "an unmasked frame from a client is closed with 1002")
  (assert (= 1007 ((raw-frame (frame/encode :text "\xff\xfe"
                                            {:mask "abcd"})) :code))
          "text that is not UTF-8 is closed with 1007")
  (assert (= 1009 ((raw-frame (frame/encode :text (string/repeat "x" 5000)
                                            {:mask "abcd"})) :code))
          "a message over :max-message is closed with 1009")

  # -- a handler that throws kills its connection and nothing else -------

  # the error this logs is the point of the test, and a suite that
  # printed it would read like a failure
  (log/set-level! "void.ws" :fatal)
  (def bc (wsc/connect (url "/boom")))
  (wsc/send! bc "go")
  (def closed (wsc/receive bc))
  (assert (= :close (closed :type)) "the connection is closed")
  (assert (= 1011 (closed :code))
          "and with 1011: the failure was the server's, and it says so")

  (log/set-level! "void.ws" :error)

  (def still (wsc/connect (url "/echo")))
  (wsc/send! still "the process is fine")
  (assert (= "the process is fine" ((wsc/receive still) :data)))
  (wsc/close! still)

  # -- a peer that stops answering pings is dropped ----------------------
  #
  # The sweeper pings anything silent for :ping-interval and abandons
  # what has not answered within :pong-timeout. Here the peer never
  # reads, so it never pongs.

  (def deaf (net/connect "127.0.0.1" (string port)))
  (:write deaf (string "GET /echo HTTP/1.1\r\nHost: t\r\n"
                       "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                       "Sec-WebSocket-Version: 13\r\n"
                       "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"))
  (wait-for |(pos? (length (ws/connections))) 3 "the deaf peer connected")
  (wait-for |(zero? (length (ws/connections))) 5
            "the sweeper reaped the peer that never answered a ping")
  (protect (:close deaf))

  # -- the refusals ------------------------------------------------------

  (each [path want]
    # an ordinary route answers an upgrade request the way it answers
    # everything: with its own response. The client refuses to speak
    # frames to it, which is the check that matters
    [["/plain" "200"]
     ["/nowhere" "404"]]
    (def [ok2 err2] (protect (wsc/connect (url path))))
    (assert (not ok2) (string/format "%s does not upgrade" path))
    (assert (string/find want (string err2))
            (string/format "%s is refused with %s" path want)))

  # -- counters ----------------------------------------------------------

  (def s (ws/stats))
  (assert (pos? (s :opened)))
  (assert (pos? (s :messages-in)))
  (assert (pos? (s :messages-out)))
  (assert (pos? (s :pings)) "the sweeper's pings are counted"))

(print "socket ok")
