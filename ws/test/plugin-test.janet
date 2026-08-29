(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/router :as router)
(import void/http/ring :as ring)
(require "void/http/init")
(import void/ws :as ws)
(import void/ws/rooms :as rooms)
(import void/ws/conn :as conn)
(import void/ws/frame :as frame)

(log/set-level! "void" :error)

(defn socket [req] (ws/accept req {}))
(defn plain [req] (ring/text 200 "ok"))

(defn- app [routes]
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/ws ">=0.0.1"}
    :contributes {:void.http/route-source
                  [{:name :test/app :routes routes
                    :env (router/env-ref (curenv))}]}))

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error}
                         :http {:port 0 :strict-meta true}}
                        extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report
  (plugin/dry-run {:plugins [:void/http :void/ws
                             (app (router/routes {}
                                    (router/GET "/live" 'socket
                                      {:name :live :void.ws/socket true})))]
                   :profile :test
                   :config (config {})}))
(assert (report :ok) "the composition validates")
(assert (index-of :ws/registry (report :components))
        "and it brings the one component that holds the connections")

# and the mark is declared through the kernel's own point rather than
# invented: the routes above carry :void.ws/socket under
# :strict-meta true, where an undeclared metadata key is a boot error.

# -- the config slice is validated before anything listens ---------------

(each [slice reason]
  [[{:ws {:send-queue 0}} "a queue that holds nothing"]
   [{:ws {:overflow :sometimes}} "an overflow policy that is not one"]
   [{:ws {:max-frame 10}} "a frame limit below a control frame"]
   [{:ws {:max-connections 0}} "a server that accepts no connections"]
   [{:ws {:ping-interval -1}} "a negative heartbeat"]]
  (def [ok] (protect (plugin/dry-run
                       {:plugins [:void/http :void/ws
                                  (app (router/routes {}
                                         (router/GET "/live" 'socket
                                           {:name :live :void.ws/socket true})))]
                        :profile :test
                        :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- a deadline on a socket route fails the boot -------------------------
#
# This is the whole reason the mark exists: a :void.http/timeout would
# cancel the connection a few seconds into the conversation, and the
# failure would look like a network problem in production rather than
# like the configuration error it is.

(def [ok err]
  (protect
    (plugin/start!
      {:plugins [:void/http :void/ws
                 (app (router/routes {}
                        (router/GET "/live" 'socket
                          {:name :live :void.ws/socket true
                           :void.http/timeout 30})))]
       :profile :test
       :config (config {})})))
(assert (not ok) "a socket route with a handler deadline does not start")
(assert (string/find "websocket lives longer" (string err))
        "and the error says why, not just that")

# -- an unmarked route that answers a handshake ---------------------------

(def boot
  (plugin/start!
    {:plugins [:void/http :void/ws
               (app (router/routes {}
                      (router/GET "/unmarked" 'socket {:name :unmarked})
                      (router/GET "/plain" 'plain {:name :plain})))]
     :profile :test
     :config (config {})}))

(defer (plugin/shutdown! boot 3)
  (def reg (get-in boot [:system :instances :ws/registry]))
  (assert reg "the registry component started")
  (assert (= reg (ws/registry)) "and the module surface reaches it")

  (def st (ws/status))
  (assert (zero? (st :connections)))
  (assert (= 4096 (st :limit)) "the default connection limit is the documented one")
  (assert (st :sweeping) "the sweeper is running")
  (assert (= (os/getpid) (st :pid))
          "the status names its process — in prefork every worker has its own registry (ADR-0010)")

  (def resp
    (let [[ok3 e]
          (protect
            ((get-in boot [:system :instances :http/kernel :handler])
             ((get-in boot [:system :instances :http/kernel :make-request])
              {:uri "/unmarked"
               :headers {"upgrade" "websocket"
                         "connection" "Upgrade"
                         "sec-websocket-version" "13"
                         "sec-websocket-key" "dGhlIHNhbXBsZSBub25jZQ=="}})))]
      (if ok3 e e)))
  (assert (= 500 (resp :status))
          "a route that answers a handshake without the mark fails loudly")

  # the same request through a marked route would upgrade; through an
  # ordinary one it is just a request
  (def plain-resp
    ((get-in boot [:system :instances :http/kernel :handler])
     ((get-in boot [:system :instances :http/kernel :make-request])
      {:uri "/plain"})))
  (assert (= 200 (plain-resp :status))))

# -- the registry, without any of the rest -------------------------------

(def reg (rooms/make {:max-connections 2 :sweep-interval 0}))
(defn- fake [id]
  (def c (conn/make @{:write (fn [_ _] nil) :close (fn [_] nil)}
                    {:send-queue 2}))
  c)

(def a (fake 1))
(def b (fake 2))
(rooms/register! reg a)
(rooms/register! reg b)
(assert (rooms/full? reg) "two connections fill a two-connection registry")

(rooms/join! reg a :news)
(rooms/join! reg b :news)
(rooms/join! reg b :sport)
(assert (= 2 (length (rooms/members reg :news))))
(assert (= [:news :sport] (rooms/room-names reg)))
(assert (= 2 (rooms/broadcast! reg :news "hello")))
(assert (= 1 (rooms/broadcast! reg :news "hello" {:except a}))
        ":except leaves the sender out — the one option a chat needs")

(def [bad] (protect (rooms/join! reg a "news")))
(assert (not bad) "a room name is a keyword, not a string")

(rooms/unregister! reg b)
(assert (= 1 (length (rooms/members reg :news))))
(assert (= [:news] (rooms/room-names reg))
        "a room with nobody in it stops existing — a room is its members")

# -- a full queue closes the connection, and counts it -------------------

(conn/reset-stats!)
(def slow (conn/make @{:write (fn [_ _] nil) :close (fn [_] nil)}
                     {:send-queue 1 :overflow :close}))
# nothing drains it: the writer fiber is not started outside `serve`
(assert (conn/enqueue! slow (frame/encode :text "one")))
(assert (not (conn/enqueue! slow (frame/encode :text "two")))
        "the second frame does not fit")
(assert (conn/closed? slow)
        "and the connection is closed rather than quietly missing it")
(assert (= 1 ((conn/stats) :overflows)))

(def lossy (conn/make @{:write (fn [_ _] nil) :close (fn [_] nil)}
                      {:send-queue 1 :overflow :drop}))
(assert (conn/enqueue! lossy (frame/encode :text "one")))
(assert (not (conn/enqueue! lossy (frame/encode :text "two"))))
(assert (conn/open? lossy)
        "with :drop the connection survives the gap it was told to accept")
(assert (= 1 (lossy :dropped)))

(print "plugin ok")
