### The one thing the kernel does for a protocol it knows nothing
### about: write the head, hand over the socket, and stop being HTTP
### (ring/upgrade). void/ws is the first caller; this suite has its own
### two-line protocol instead, because the seam is the kernel's and
### should be provable without the package that uses it.

(import ../test-support/paths)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/http/wire :as wire)

(def taken @[])

(defn- app [req]
  (case (req :path)
    "/upgrade"
    (ring/upgrade @{"upgrade" "echo" "connection" "Upgrade"}
                  (fn take-over [conn leftover]
                    (array/push taken leftover)
                    # the whole protocol: shout back whatever is said,
                    # until the peer stops talking
                    (:write conn (string ">" leftover))
                    (def buf @"")
                    (while (net/read conn 256 buf 2)
                      (:write conn (string ">" buf))
                      (buffer/clear buf))))

    "/upgrade-boom"
    (ring/upgrade @{"upgrade" "echo"} (fn boom [conn leftover] (error "handed over and exploded")))

    "/plain" (ring/text 200 "plain")

    (ring/not-found)))

(def inst (server/start {:handler app :port "0" :idle-timeout 1}))
(def port (string (inst :port)))

(defn- read-until [conn buf want &opt timeout]
  (default timeout 2)
  (def deadline (+ (os/clock :monotonic) timeout))
  (while (and (not (string/find want buf)) (< (os/clock :monotonic) deadline))
    (unless (net/read conn 4096 buf 1) (break)))
  (string buf))

(defer (server/stop inst 1)

  # -- the head goes out, then the socket belongs to somebody else -------

  (def c (net/connect "127.0.0.1" port))
  (:write c "GET /upgrade HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\n\r\n")
  (def buf @"")
  (read-until c buf "\r\n\r\n")
  (def head (wire/parse-response-head buf))
  (assert (= 101 (head :status)) "the 101 is an ordinary response")
  (assert (= "echo" (get-in head [:headers "upgrade"])))
  (assert (nil? (get-in head [:headers "connection-close"])))
  (assert (nil? (get-in head [:headers "content-length"]))
          "a 101 carries no body framing — the bytes after it are not a body")

  (def rest (buffer (string/slice buf (head :head-size))))
  (:write c "hello")
  (assert (string/find ">hello" (read-until c rest ">hello"))
          "what the peer writes now reaches the protocol that took over")
  (:close c)

  # -- bytes that arrived behind the head are handed over, not dropped ---
  #
  # A client is allowed to send its first frame in the same packet as
  # the request. Losing it would lose a message before the new protocol
  # said a word — see ring/upgrade.

  (def c2 (net/connect "127.0.0.1" port))
  (:write c2 (string "GET /upgrade HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\n\r\n"
                     "already-here"))
  (def buf2 @"")
  (read-until c2 buf2 ">already-here")
  (assert (string/find ">already-here" (string buf2))
          "the leftover bytes reached the new protocol")
  (assert (index-of "already-here" taken))
  (:close c2)

  # -- a protocol that throws does not put HTTP back on the socket -------

  (def c3 (net/connect "127.0.0.1" port))
  (:write c3 "GET /upgrade-boom HTTP/1.1\r\nHost: t\r\n\r\n")
  (def buf3 @"")
  (read-until c3 buf3 "\r\n\r\n")
  (def head3 (wire/parse-response-head buf3))
  (assert (= 101 (head3 :status)))
  (def after (buffer (string/slice buf3 (head3 :head-size))))
  (read-until c3 after "HTTP/1.1" 0.5)
  (assert (not (string/find "HTTP/1.1" (string after)))
          "no 500 lands in the middle of somebody else's byte stream")
  (:close c3)

  # -- and the server is still a server ----------------------------------

  (def c4 (net/connect "127.0.0.1" port))
  (:write c4 "GET /plain HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  (def buf4 @"")
  (read-until c4 buf4 "plain")
  (assert (string/find "200 OK" (string buf4)))
  (:close c4)

  # -- the response is a table like any other ----------------------------

  (def [ok] (protect (ring/upgrade @{} "not a function")))
  (assert (not ok) "ring/upgrade needs something to hand the socket to"))

(print "upgrade ok")
