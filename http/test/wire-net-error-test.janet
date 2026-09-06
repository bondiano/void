### net-error-kind: what a socket error means, without reading its
### prose twice.
###
### Two halves. The table half pins the texts janet's net raises on
### macOS and Linux — the ones the server, the client and ws used to
### match by substring, each with its own list — to the kind each
### means. The live half produces the errors this OS actually raises
### (a read that times out, a stream closed under a parked read, a
### peer that reset, a write into a broken pipe) and asserts the
### classifier reads them the same way: the table is only as good as
### its agreement with the running janet.

(import ../test-support/paths)
(import void/core/errors :as errors)
(import void/http/wire :as wire)

# -- the table -----------------------------------------------------------

(def by-text
  # text -> kind; every text a read loop ever matched a substring of
  {"timeout" :timeout                         # janet, net/read with a timeout
   "Operation timed out" :timeout             # macOS ETIMEDOUT
   "Connection timed out" :timeout            # Linux ETIMEDOUT
   "Connection reset by peer" :reset          # ECONNRESET, both
   "Broken pipe" :reset                       # EPIPE, both
   "Software caused connection abort" :reset  # ECONNABORTED
   "stream closed" :reset                     # janet, write after a hang-up
   "stream err" :reset                        # janet, the poll loop's error event
   "stream is closed" :closed                 # janet, using a closed stream
   "Bad file descriptor" :closed              # EBADF
   "Socket is not connected" :closed          # ENOTCONN
   "deadline expired" :cancelled              # ev/deadline
   "parent canceled" :cancelled
   "sibling canceled" :cancelled})

(eachp [text kind] by-text
  (assert (= kind (wire/net-error-kind text))
          (string/format "%q is %q" text kind))
  (assert (= kind (wire/net-error-kind (buffer text)))
          "a buffer classifies like the string"))

# exact texts: a message that merely mentions one is something else
(each text ["handler timeout exceeded"
            "the stream is closed for business"
            "Connection reset by peer while parsing"
            "deadline expired twice"
            ""]
  (assert (= :other (wire/net-error-kind text))
          (string/format "%q is not a socket error" text)))

# the whole set is closed
(def kinds (distinct (map wire/net-error-kind (keys by-text))))
(assert (deep= (sorted kinds) (sorted [:timeout :reset :closed :cancelled]))
        "every text lands in one of the four named kinds")

# -- the error shape of 8.1 ----------------------------------------------

(assert (= :cancelled (wire/net-error-kind (errors/make :void/deadline)))
        "a :void/deadline envelope is a cancellation")
(assert (= :cancelled (wire/net-error-kind (errors/of errors/deadline-message)))
        "errors/of the deadline value agrees with the bare value")
(assert (= :reset (wire/net-error-kind (errors/of "Broken pipe")))
        "a panic envelope is classified by the text it wraps")
(assert (= :other (wire/net-error-kind (errors/make :void.db/timeout "statement cancelled")))
        "another package's timeout is not a socket timeout")
(assert (= :other (wire/net-error-kind (errors/make :void/panic "handler exploded"))))

# what a cancel can carry, and what a read loop must not mistake for
# a peer going away
(each v [:void.http/consumer-gone {:void.http/timeout true} nil 42 @{}]
  (assert (= :other (wire/net-error-kind v))
          (string/format "%q is :other" v)))

(assert (wire/peer-gone? :reset))
(assert (wire/peer-gone? :closed))
(each k [:timeout :cancelled :other]
  (assert (not (wire/peer-gone? k)) (string/format "%q is not the peer leaving" k)))

# -- the live half: what this OS's janet actually raises ------------------

(defn- caught
  "The value a thunk raised, or [:ok value] when it did not."
  [thunk]
  (def [ok res] (protect (thunk)))
  (if ok [:ok res] res))

(def srv (net/listen "127.0.0.1" "0"))
(def [_ port] (net/localname srv))
(defn- pair
  "A connected [client server] pair of sockets."
  []
  (def c (net/connect "127.0.0.1" (string port)))
  (def s (net/accept srv))
  [c s])

(defer (:close srv)
  # a read that runs out of its timeout
  (let [[c s] (pair)]
    (assert (= :timeout (wire/net-error-kind (caught |(net/read s 10 @"" 0.05))))
            "a read timeout is :timeout")
    (:close c) (:close s))

  # a stream closed on this side, then used
  (let [[c s] (pair)]
    (:close s)
    (assert (= :closed (wire/net-error-kind (caught |(net/read s 10 @"" 1))))
            "reading a closed stream is :closed")
    (assert (= :closed (wire/net-error-kind (caught |(net/write s "x"))))
            "writing a closed stream is :closed")
    (:close c))

  # a peer that closed with data unread on its side — a reset — then
  # our read, and our writes into the broken pipe
  (let [[c s] (pair)]
    (net/write s "unread")
    (ev/sleep 0.02)
    (:close c)
    (ev/sleep 0.05)
    (def big (string/repeat "x" 100000))
    (def kinds @[])
    (array/push kinds (wire/net-error-kind (caught |(net/read s 10 @"" 1))))
    (array/push kinds (wire/net-error-kind (caught |(net/write s big))))
    (array/push kinds (wire/net-error-kind (caught |(net/write s big))))
    (each k kinds
      (assert (= :reset k) (string/format "after a peer reset every error is :reset, got %q" k)))
    (:close s))

  # a cancelled task: the value the cancel carried, not a socket error
  (let [[c s] (pair)]
    # supervised, so the cancellations are values here rather than
    # stack traces on stderr
    (def sup (ev/chan 2))
    (def f (ev/go (fn [] (net/read s 10 @"" 5)) nil sup))
    (ev/sleep 0.02)
    (ev/cancel f :stop)
    (ev/take sup)
    (assert (= :other (wire/net-error-kind (fiber/last-value f)))
            "an application's own cancel value is :other, for the caller to re-raise")
    (def g (ev/go (fn [] (ev/deadline 0.05) (net/read s 10 @"" 5)) nil sup))
    (ev/take sup)
    (assert (= :cancelled (wire/net-error-kind (fiber/last-value g)))
            "a deadline landing in a parked read is :cancelled")
    (:close c) (:close s)))

(print "wire-net-error-test: all assertions passed")
