(import ../test-support/paths)
(import ../test-support/server)
(import void/redis/conn :as conn)
(import void/redis/config :as config)
(import void/redis/resp :as resp)

(if-not (server/available?)
  (server/skip "conn-test")
  (do
    (def opts (config/options {:url (server/url)}))
    (def prefix (server/prefix "conn"))
    (def c (conn/open opts))

    (defer (conn/close c)

      # -- the handshake -----------------------------------------------

      (def info (conn/info c))
      (assert (conn/open? c) "the connection is open")
      (assert (or (= 2 (info :protocol)) (= 3 (info :protocol)))
              "and speaks a protocol it agreed on")
      (when (= 3 (info :protocol))
        (assert (info :server-version) "RESP3 means HELLO answered, version included")
        (assert (info :client-id) "and gave us the id CLIENT KILL takes"))

      # -- ordinary commands -------------------------------------------

      (def k (string prefix "k"))
      (assert (= "OK" (conn/call c ["SET" k "hello"])))
      (assert (= "hello" (conn/call c ["GET" k])))
      (assert (nil? (conn/call c ["GET" (string prefix "absent")]))
              "a missing key is nil, in either protocol")
      (assert (= 1 (conn/call c ["DEL" k])))

      # -- big values --------------------------------------------------
      #
      # The point is the reader: a value larger than any one read is
      # where a client that scans for a terminator instead of using the
      # length prefix goes quadratic, or wrong.

      (def big (string/repeat "x" 300000))
      (conn/call c ["SET" k big])
      (assert (= 300000 (length (conn/call c ["GET" k])))
              "a value bigger than a socket read comes back whole")
      (assert (= big (conn/call c ["GET" k])) "and unchanged")
      (conn/call c ["DEL" k])

      # -- errors ------------------------------------------------------

      (conn/call c ["SET" k "string"])
      (def [ok err] (protect (conn/call c ["LPUSH" k "x"])))
      (assert (not ok) "an error reply throws")
      (assert (conn/error? err) "as a structured error")
      (assert (= "WRONGTYPE" (conn/error-code err)) "with the code to branch on")
      (assert (not (conn/fatal? err)) "and the connection is fine — it was the command that failed")
      (assert (= "LPUSH" (err :command)) "which command earned it")
      (assert (conn/open? c) "so the connection stays usable")
      (assert (= "string" (conn/call c ["GET" k])) "demonstrably")

      (def raw (conn/call c ["LPUSH" k "x"] {:raw true}))
      (assert (resp/error? raw) ":raw hands the error back as a value instead")
      (conn/call c ["DEL" k])

      # -- pipelining --------------------------------------------------

      (def n (string prefix "n"))
      (def replies (conn/pipeline c [["INCR" n] ["INCR" n] ["INCR" n] ["DEL" n]]))
      (assert (deep= @[1 2 3 1] replies)
              "every reply comes back, in the order the commands went out")
      (assert (empty? (conn/pipeline c [])) "an empty pipeline is not a round trip")

      (conn/call c ["SET" k "string"])
      (def [pok perr] (protect (conn/pipeline c [["INCR" n] ["LPUSH" k "x"] ["INCR" n]])))
      (assert (not pok) "a failed command in a pipeline throws")
      (assert (= 1 (perr :index)) "saying which one")
      (assert (= 3 (length (perr :results)))
              "and keeping the replies around it — the server ran them all")
      (assert (= 2 (get-in perr [:results 2]))
              "including the ones after the failure")
      (conn/call c ["DEL" k n])

      # -- the reply stream stays in step ------------------------------

      (assert (= "PONG" (conn/call c ["PING"]))
              "after all of that, the next reply is still this caller's")

      # -- a blocking command outlives the read timeout ----------------
      #
      # A read timeout exists to notice a server that stopped
      # answering. BLPOP is a server that was *told* not to answer yet,
      # so the two have to be separable — or every blocking command
      # breaks its own connection.

      (def slow (conn/open (merge opts {:timeout 0.3})))
      (def queue (string prefix "quiet"))
      (assert (nil? (conn/call slow ["BLPOP" queue 1] {:timeout conn/no-timeout}))
              "with :timeout :none the wait runs to the end the server was given")
      (def [tok terr] (protect (conn/call slow ["BLPOP" queue 1])))
      (assert (not tok) "and without it the read timeout fires first")
      (assert (conn/fatal? terr)
              "fatally: the reply is still coming, so the connection can never be trusted again")
      (conn/close slow)

      # -- reconnect ---------------------------------------------------

      (def before (conn/info c))
      (conn/reconnect! c)
      (def after (conn/info c))
      (assert (= 1 (- (after :generation) (before :generation)))
              "reconnecting counts as a new generation")
      (assert (= (before :id) (after :id))
              "on the same connection value — whatever holds it keeps working")
      (assert (= "PONG" (conn/call c ["PING"])) "and it works")

      # -- a dead connection says so -----------------------------------

      (def victim (conn/open opts))
      (:close (victim :stream))
      (def [dok derr] (protect (conn/call victim ["PING"])))
      (assert (not dok) "a command on a closed socket fails")
      (assert (conn/fatal? derr) "fatally — the pool must not hand this on")
      (assert (not (conn/open? victim)) "and the connection knows it")
      (conn/close victim))

    # -- the loop is not blocked ---------------------------------------
    #
    # The claim a pure-Janet client makes: a command in
    # flight parks its fiber, it does not stop the loop. Four
    # connections wait a second each on BLPOP while a ticker runs.

    (def conns (seq [_ :range [0 4]] (conn/open opts)))
    (var ticks 0)
    (var ticking true)
    (ev/go (fn tick []
             (while ticking
               (ev/sleep 0.02)
               (++ ticks))))
    (def t0 (os/clock :monotonic))
    (def sup (ev/chan (length conns)))
    (def waiters
      (seq [[i c] :pairs conns]
        (ev/go (fn wait []
                 (conn/call c ["BLPOP" (string prefix "queue" i) 1] {:timeout 3}))
               nil sup)))
    (each _ waiters (ev/take sup))
    (def elapsed (- (os/clock :monotonic) t0))
    (set ticking false)
    (each c conns (conn/close c))

    (assert (< elapsed 2)
            (string/format "four one-second waits overlapped (took %.2fs, not 4s)" elapsed))
    (assert (> ticks 20)
            (string/format "and the loop kept running underneath them (%d ticks)" ticks))

    (printf "conn-test: ok")))
