# A fake RESP server: a real net/server on an ephemeral port that
# answers each command it receives with pre-scripted bytes. It exists
# to exercise the paths a well-behaved redis never takes — a frame the
# grammar refuses, a reply that never comes, a bulk header promising
# gigabytes, a socket closed mid-conversation — without a redis
# anywhere, which is what lets these tests gate CI instead of skipping.
#
# The script is per connection: `script-for` is (fn [n] steps), with
# `n` counting accepted connections from 0. Each step answers one
# incoming command, in order:
#
#     bytes                 written as the reply (may carry several
#                           frames — a subscribe confirmation plus a
#                           push, say)
#     :silent               consume the command, answer nothing
#     :close                close the connection instead of answering
#     [:close-after bytes]  write the bytes, then close
#
# A connection that runs out of steps stays open and silent, so a test
# ends on its own assertions rather than on a surprise EOF.
#
# Open clients against it with `opts`: it pins {:protocol 2}, under
# which the handshake sends nothing (no HELLO, no AUTH, no SELECT) —
# the script counts only the commands the test itself sends.

(import void/redis/codec :as codec)
(import void/redis/pool :as pool)
(import void/redis/resp :as resp)

(defn- read-frame
  "The end index of one complete RESP frame at `pos`, reading more as
  needed; nil once the client hangs up."
  [stream buf pos]
  (var out nil)
  (var done false)
  (while (not done)
    (def [state n] (resp/scan buf pos))
    (if (= :done state)
      (do (set out n) (set done true))
      (let [[ok got] (protect (:read stream (max 4096 (- n (length buf))) buf 30))]
        (when (or (not ok) (nil? got))
          (set done true)))))
  out)

(defn- handle
  [h stream steps n]
  (def buf @"")
  (var pos 0)
  (var i 0)
  (var open true)
  (while open
    (def end (read-frame stream buf pos))
    (if (nil? end)
      (set open false)
      (do
        (array/push (h :received) [n (string/slice buf pos end)])
        (set pos end)
        (def step (get steps i))
        (++ i)
        (match step
          :close (set open false)
          :silent nil
          nil nil
          [:close-after bytes] (do (protect (:write stream bytes))
                                   (set open false))
          bytes (unless (first (protect (:write stream bytes)))
                  (set open false))))))
  (protect (:close stream)))

(defn start
  ``A listening fake, as @{:host :port :connections :received ...}.
  `:connections` counts accepted connections; `:received` collects
  [connection-index command-bytes] pairs as they arrive.``
  [script-for]
  (def h @{:connections 0 :received @[] :streams @[]})
  (def server
    (net/server "127.0.0.1" 0
                (fn serve-one [stream]
                  (def n (h :connections))
                  (put h :connections (inc n))
                  (array/push (h :streams) stream)
                  (handle h stream (script-for n) n))))
  (def [host port] (net/localname server))
  (put h :server server)
  (put h :host host)
  (put h :port port)
  h)

(defn stop
  "Close the listener and every connection it accepted."
  [h]
  (protect (:close (h :server)))
  (each s (h :streams) (protect (:close s)))
  nil)

(defn opts
  ``Connection options against this fake: RESP2 (so the handshake is
  silent) and short timeouts (so a scripted non-answer fails the test
  in seconds, not minutes).``
  [h &opt extra]
  (merge {:host (h :host) :port (h :port) :protocol 2
          :connect-timeout 2 :timeout 2}
         (or extra {})))

(defn commands
  "The commands connection `n` received, as raw RESP bytes."
  [h n]
  (map |(in $ 1) (filter |(= n (in $ 0)) (h :received))))

(defn client
  ``A client value over this fake — a pool, the raw codec, no prefix —
  for binding into state/client-dyn, the way test-support/server builds
  one over a real redis.``
  [h &opt extra pool-opts]
  (def conn-opts (opts h extra))
  @{:pool (pool/make conn-opts (merge {:size 4 :checkout-timeout 2}
                                      (or pool-opts {})))
    :codec codec/raw
    :prefix ""
    :retry true
    :conn-opts conn-opts})
