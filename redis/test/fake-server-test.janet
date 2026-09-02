(import ../test-support/paths)
(import ../test-support/fake)
(import void/redis/codec :as codec)
(import void/redis/config :as config)
(import void/redis/conn :as conn)
(import void/redis/pool :as pool)
(import void/redis/pubsub :as pubsub)
(import void/redis/resp :as resp)
(import void/redis/state :as state)

# What a real redis never sends, this suite does: every test here runs
# against test-support/fake, so it needs no server and gates CI.

# -- the scanner and the grammar agree ------------------------------------
#
# `scan` frames a reply, `parse` decodes it, and :pos only ever moves
# by what `parse` returned. A frame the scanner steps over but the
# grammar refuses used to leave :pos stuck on the same byte for every
# next owner of the connection; now either the scanner throws too, or
# the connection is broken on the spot.

(def bad-frames
  ["$-2\r\n"        # a negative length that is not the null marker
   "#x\r\n"         # a boolean that is neither #t nor #f
   "$1e3\r\nx\r\n"  # a length only scan-number would read
   ",abc\r\n"       # a double that is not a number
   "$5\r\nhelloXX"])# a bulk without its trailing CRLF

(each bad bad-frames
  # unit half: scan either refuses the bytes outright or agrees with
  # the grammar that this is one frame — never "done" over bytes the
  # PEG then rejects while both stay silent
  (def [sok sres] (protect (resp/scan bad)))
  (when (and sok (= :done (first sres)))
    (def [pok pres] (protect (resp/parse bad)))
    (assert (or (not pok) (nil? pres))
            (string/format "%q: parse agrees the frame is bad" bad)))

  # connection half: the reply breaks the connection, fatally
  (def h (fake/start (fn [_] [bad])))
  (def c (conn/open (fake/opts h)))
  (def [ok err] (protect (conn/call c ["GET" "k"])))
  (assert (not ok) (string/format "%q is not a reply" bad))
  (assert (conn/fatal? err)
          (string/format "%q breaks the connection, not just the command" bad))
  (assert (not (conn/open? c))
          (string/format "%q leaves the connection marked broken" bad))
  (conn/close c)
  (fake/stop h))

# -- a poisoned connection never returns to the pool ---------------------

(do
  (def h (fake/start (fn [n] (case n
                               0 ["#x\r\n"]
                               1 ["+PONG\r\n"]))))
  (def client (fake/client h))
  (defer (do (pool/close-all! (client :pool)) (fake/stop h))
    (with-dyns [state/client-dyn client]
      (def [ok err] (protect (state/call ["GET" "k"])))
      (assert (not ok) "the poisoned frame fails the command")
      (assert (conn/fatal? err) "fatally")
      (assert (= "PONG" (state/call ["PING"]))
              "and the next command still works —")
      (assert (= 2 (h :connections))
              "on a fresh connection, not the poisoned one"))))

# -- an open MULTI is discarded, a clean error is not --------------------

(do
  (def h (fake/start (fn [n] (case n
                               0 ["+OK\r\n"]
                               1 ["+PONG\r\n"]))))
  (def client (fake/client h))
  (defer (do (pool/close-all! (client :pool)) (fake/stop h))
    (with-dyns [state/client-dyn client]
      (def [ok _] (protect (state/with-conn* (fn abandoned [_]
                                               (state/call ["MULTI"])
                                               (error "boom")))))
      (assert (not ok) "the scope failed after MULTI")
      (assert (= "PONG" (state/call ["PING"])) "the next command works —")
      (assert (= 2 (h :connections))
              "on a fresh connection: a connection abandoned inside MULTI
              is closed, never handed to the next owner"))))

(do
  # the positive control: MULTI closed by EXEC leaves the connection
  # clean, and clean connections are reused
  (def h (fake/start (fn [_] ["+OK\r\n" "+QUEUED\r\n" "*1\r\n:1\r\n" "+PONG\r\n"])))
  (def client (fake/client h))
  (defer (do (pool/close-all! (client :pool)) (fake/stop h))
    (with-dyns [state/client-dyn client]
      (def r (state/with-conn* (fn tx [_]
                                 (state/call ["MULTI"])
                                 (state/call ["INCR" "n"])
                                 (state/call ["EXEC"]))))
      (assert (deep= @[1] r) "the transaction ran")
      (assert (= "PONG" (state/call ["PING"])))
      (assert (= 1 (h :connections)) "on the same connection throughout"))))

(do
  # an error *reply* is a failed command on a healthy connection: every
  # sent command was answered, so nothing is discarded
  (def h (fake/start (fn [_] ["-WRONGTYPE not a list\r\n" "+PONG\r\n"])))
  (def client (fake/client h))
  (defer (do (pool/close-all! (client :pool)) (fake/stop h))
    (with-dyns [state/client-dyn client]
      (def [ok err] (protect (state/call ["LPUSH" "k" "x"])))
      (assert (and (not ok) (not (conn/fatal? err))) "the command failed, the connection did not")
      (assert (= "PONG" (state/call ["PING"])))
      (assert (= 1 (h :connections)) "and the connection was reused"))))

# -- a blocking command is never retried ---------------------------------

(do
  (def h (fake/start (fn [n] (case n
                               0 ["+PONG\r\n" :silent]
                               1 ["+PONG\r\n"]))))
  (def client (fake/client h {:timeout 0.3}))
  (defer (do (pool/close-all! (client :pool)) (fake/stop h))
    (with-dyns [state/client-dyn client]
      (assert (= "PONG" (state/call ["PING"])) "warmed: the connection is idle, not fresh")
      (def [ok err] (protect (state/call ["BLPOP" "q" 5])))
      (assert (not ok) "the silent server times the read out")
      (assert (conn/fatal? err) "which breaks the connection")
      (assert (= 1 (h :connections))
              "and BLPOP is NOT replayed on a fresh connection — the
              element its lost reply may have carried would be taken twice")
      (assert (= 2 (length (fake/commands h 0)))
              "the server saw PING and one BLPOP, nothing more"))))

(do
  # the contrast that keeps the retry honest: a non-blocking command on
  # a stale idle socket is still retried once
  (def h (fake/start (fn [n] (case n
                               0 ["+PONG\r\n" :close]
                               1 ["$1\r\na\r\n"]))))
  (def client (fake/client h))
  (defer (do (pool/close-all! (client :pool)) (fake/stop h))
    (with-dyns [state/client-dyn client]
      (assert (= "PONG" (state/call ["PING"])))
      (assert (= "a" (state/call ["GET" "k"]))
              "the GET whose socket died was replayed")
      (assert (= 2 (h :connections)) "on a fresh connection"))))

# -- the bulk cap --------------------------------------------------------

(do
  (assert (= (* 64 1024 1024) (get (config/options {}) :max-bulk))
          "the cap defaults on, at 64 MB")
  (assert (= 1024 (get (config/options {:max-bulk 1024}) :max-bulk))
          "and [:redis :max-bulk] sets it")

  (def h (fake/start (fn [_] ["$2000000000\r\n"])))
  (def c (conn/open (fake/opts h {:max-bulk (* 1024 1024)})))
  (def [ok err] (protect (conn/call c ["GET" "k"])))
  (assert (not ok) "a reply claiming 2 GB is refused")
  (assert (conn/fatal? err) "fatally — the frame cannot be skipped either")
  (assert (string/find "max-bulk" (get err :message ""))
          "naming the knob that raises the cap")
  (assert (not (conn/open? c)) "and the connection is done for")
  (conn/close c)
  (fake/stop h))

# -- pub/sub: a bad payload is the message's problem ---------------------

(def- sub-ok "*3\r\n$9\r\nsubscribe\r\n$2\r\nch\r\n:1\r\n")

(defn- message [payload]
  (string "*3\r\n$7\r\nmessage\r\n$2\r\nch\r\n"
          "$" (length payload) "\r\n" payload "\r\n"))

(defn- await [pred what]
  (var tries 0)
  (while (and (not (pred)) (< tries 200))
    (ev/sleep 0.01)
    (++ tries))
  (assert (pred) what))

(do
  (def h (fake/start (fn [_] [(string sub-ok
                                      (message "not-json{")
                                      (message `"hi"`))])))
  (def l (pubsub/open (fake/opts h) {:codec codec/json}))
  (def got @[])
  (pubsub/subscribe! l "ch" (fn [m] (array/push got (m :payload))))
  (await |(not (empty? got)) "the decodable message arrived")
  (assert (deep= @["hi"] got) "decoded")
  (assert (= 1 (get-in l [:stats :errors]))
          "the undecodable one was counted and dropped")
  (assert (zero? (get-in l [:stats :reconnects]))
          "without taking the connection down")
  (pubsub/stop! l)
  (fake/stop h))

# -- pub/sub: stop! + start! leaves one reader ---------------------------

(do
  # every connection answers its SUBSCRIBE with one message: delivery
  # count equals reader count, and a stale reader surviving a
  # stop!/start! pair would push it past one per start
  (def h (fake/start (fn [_] [(string sub-ok (message "m"))])))
  (def l (pubsub/open (fake/opts h)))
  (var hits 0)
  (pubsub/subscribe! l "ch" (fn [_] (++ hits)))
  (await |(= 1 hits) "the first reader delivered once")
  (pubsub/stop! l)
  (pubsub/start! l)
  (await |(>= hits 2) "the restarted reader delivered")
  (ev/sleep 0.3)
  (assert (= 2 hits)
          "exactly once: the superseded reader left instead of serving
          alongside its successor")
  (pubsub/stop! l)
  (fake/stop h))

# -- pub/sub: the backoff resets after a successful connect --------------

(do
  # a server that greets and hangs up, over and over: with the reset,
  # every retry is a fresh incident at :min; without it the delays
  # would climb to :max and the counter would sit at 2-3
  (def h (fake/start (fn [_] [[:close-after sub-ok]])))
  (def l (pubsub/open (fake/opts h)
                      {:backoff {:min 0.02 :max 5 :factor 10}}))
  (pubsub/subscribe! l "ch" (fn [_] nil))
  (ev/sleep 1)
  (def reconnects (get-in l [:stats :reconnects]))
  (pubsub/stop! l)
  (fake/stop h)
  (assert (>= reconnects 5)
          (string/format
            "a connect that succeeded resets the backoff (saw %d reconnects in 1s)"
            reconnects)))

(printf "fake-server-test: ok")
