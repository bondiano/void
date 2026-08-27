### void/redis/pubsub — publish/subscribe on a connection of its own
### (SPEC.md §5.10, ROADMAP 2.2).
###
### A subscribed connection is not a request/response connection any
### more. In RESP2 it accepts nothing but SUBSCRIBE, UNSUBSCRIBE and
### PING, and in either protocol it may speak at any moment, without
### having been asked. That is why this cannot live on the pool: a
### pooled connection is handed to whoever asks next, and whoever asks
### next wants to run GET.
###
### So: one connection, one fiber parked in a read, and nothing else.
### It costs nothing while idle — the fiber is suspended on the ev
### loop, not spinning — and it is opened on the first subscription, so
### an application that never subscribes never opens it (ADR-0010).
###
###     (pubsub/subscribe! l "cache-invalidation"
###                        (fn [m] (cache/forget! (m :payload))))
###     (pubsub/psubscribe! l "user:*:events" handler)
###
### Two fibers do touch this connection, and that is safe because they
### use opposite directions of it: the reader fiber only reads, and a
### `subscribe!` from a request fiber only writes (under the
### connection's lock). The confirmation of that SUBSCRIBE comes back
### to the reader like any other frame.
###
### What a caller has to know, and no client can hide: delivery is
### at-most-once. Redis pub/sub has no queue, no acknowledgement and no
### replay — a message published while this connection is reconnecting
### is gone, and nobody is told. It is the right tool for
### cache invalidation, live dashboards and "something changed, go and
### look", and the wrong one for work that must happen. That work
### belongs in a stream or a list (see `void/jobs`, wave 2.4).
###
### Handlers run in the reading fiber, one after another, so a handler
### that blocks holds up every other subscriber. Keep them short; do
### the work in a fiber of your own.

(import void/core/log :as log)
(import ./codec :as codec)
(import ./conn :as conn)
(import ./resp :as resp)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.redis.pubsub")

(def default-backoff
  ``Reconnect delays in seconds: the first retry is quick because most
  disconnections are a blip, and the ceiling keeps a subscriber
  against a server that is down from becoming the reason it stays
  down.``
  {:min 0.2 :max 30 :factor 2})

(defn open
  ``Build a subscriber over connection options. Nothing is opened
  here: the connection appears with the first subscription.``
  [conn-opts &opt opts]
  (default opts {})
  @{:conn-opts conn-opts
    :codec (get opts :codec codec/raw)
    :backoff (merge default-backoff (get opts :backoff {}))
    :channels @{}
    :patterns @{}
    :conn nil
    :running false
    :fiber nil
    :stats @{:messages 0 :reconnects 0 :errors 0 :delivered 0}})

# -- what the server says ------------------------------------------------

(defn- message-of
  ``One pub/sub frame as a message, or nil when it is a subscription
  confirmation (which carries the count of live subscriptions, and
  nothing a handler wants).

  RESP3 delivers these as push frames and RESP2 as ordinary arrays on
  a connection that can carry nothing else — the same three or four
  elements either way, which is why one function reads both.``
  [l frame]
  (def items (if (resp/push? frame) (resp/push-items frame) frame))
  (when (indexed? items)
    (def kind (string (get items 0 "")))
    (def c (l :codec))
    (case kind
      "message" {:channel (string (in items 1))
                 :payload (codec/decode c (in items 2))}
      "pmessage" {:pattern (string (in items 1))
                  :channel (string (in items 2))
                  :payload (codec/decode c (in items 3))}
      nil)))

(defn- handlers-for [l msg]
  (if-let [pattern (msg :pattern)]
    (get (l :patterns) pattern)
    (get (l :channels) (msg :channel))))

(defn- deliver [l frame]
  (when-let [msg (message-of l frame)]
    (put-in l [:stats :messages] (inc (get-in l [:stats :messages])))
    (each f (or (handlers-for l msg) [])
      (def [ok err] (protect (f msg)))
      (if ok
        (put-in l [:stats :delivered] (inc (get-in l [:stats :delivered])))
        (do
          (put-in l [:stats :errors] (inc (get-in l [:stats :errors])))
          # one bad subscriber does not silence the rest, and does not
          # take the connection down with it
          (log/error "a subscriber handler failed" :ns log-ns
                     :channel (msg :channel) :pattern (msg :pattern)
                     :err (if (string? err) err (describe err))))))))

# -- the connection ------------------------------------------------------

(defn- desired-commands [l]
  (def out @[])
  (unless (empty? (l :channels))
    (array/push out ["SUBSCRIBE" ;(sorted (keys (l :channels)))]))
  (unless (empty? (l :patterns))
    (array/push out ["PSUBSCRIBE" ;(sorted (keys (l :patterns)))]))
  out)

(defn- ensure-conn [l]
  ``The connection, opened and brought up to date with what is
  subscribed. Reconnecting means resubscribing: a redis connection
  carries no subscription across a socket, and neither does a
  replacement for one.``
  (def existing (l :conn))
  (if (and existing (conn/open? existing))
    existing
    (do
      (when existing (conn/close existing))
      (def c (conn/open (l :conn-opts)))
      (put l :conn c)
      (each cmd (desired-commands l) (conn/send c cmd))
      c)))

(defn- serve [l]
  "Read frames until the connection fails or the subscriber stops."
  (def c (ensure-conn l))
  (while (and (l :running) (conn/open? c))
    # no read timeout: a subscriber is meant to sit silent, and the
    # only thing a timeout here could mean is "nobody published"
    (deliver l (conn/receive c {:timeout conn/no-timeout}))))

(defn- backoff-seq [l]
  (def b (l :backoff))
  (var delay (b :min))
  (fn next-delay []
    (def d delay)
    (set delay (min (b :max) (* delay (b :factor))))
    d))

(defn- reader [l]
  (def next-delay (backoff-seq l))
  (while (l :running)
    (def [ok err] (protect (serve l)))
    (when (and (not ok) (l :running))
      (put-in l [:stats :reconnects] (inc (get-in l [:stats :reconnects])))
      (when-let [c (l :conn)] (protect (conn/close c)) (put l :conn nil))
      (def delay (next-delay))
      (log/warn "the subscriber connection dropped — reconnecting" :ns log-ns
                :in delay
                :err (if (dictionary? err) (get err :message (describe err))
                       (describe err)))
      (ev/sleep delay)))
  (when-let [c (l :conn)]
    (protect (conn/close c))
    (put l :conn nil)))

(defn running?
  "Is the reading fiber alive?"
  [l]
  (truthy? (l :running)))

(defn start!
  "Start the reading fiber. Idempotent; the connection still waits for
  the first subscription."
  [l]
  (unless (l :running)
    (put l :running true)
    (put l :fiber (ev/go (fn subscriber [] (reader l)))))
  l)

(defn stop!
  "Stop reading and close the connection. In flight handlers finish;
  nothing new is delivered."
  [l]
  (put l :running false)
  (when-let [c (l :conn)]
    # closing under the reader is what wakes it: the read fails, and a
    # stopped subscriber does not reconnect
    (protect (conn/close c)))
  (put l :conn nil)
  (put l :fiber nil)
  l)

# -- subscribing ---------------------------------------------------------

(defn- register! [l table- name f]
  (def arr (or (get (l table-) name)
               (let [a @[]] (put (l table-) name a) a)))
  (array/push arr f)
  (= 1 (length arr)))

(defn- send-now [l cmd]
  ``Send a subscription command on the live connection, if there is
  one — and do nothing when there is not.

  The connection is opened by the reading fiber and by nothing else,
  which is what keeps two fibers from each opening one and then
  subscribing on the other's. So this is best-effort by design: the
  desired set has already been recorded, and the reader sends whatever
  it finds there when it opens or reopens the connection. Worst case
  the command is sent twice, and redis answers a repeated SUBSCRIBE
  with the same count it did the first time.``
  (when-let [c (l :conn)]
    (when (conn/open? c)
      (def [ok err] (protect (conn/send c cmd)))
      (unless ok
        (log/debug "the subscription will be sent on reconnect" :ns log-ns
                   :command (first cmd)
                   :err (if (dictionary? err) (get err :message (describe err))
                          (describe err)))))))

(defn subscribe!
  ``Call `f` with every message published to `channel`
  ({:channel :payload}). Returns `f`, which `unsubscribe!` takes back.

  Channel names are not prefixed the way keys are: a channel is not a
  key, it addresses listeners rather than data, and a name is the only
  thing the publisher and the subscriber share. Namespace them
  yourself where one redis serves several applications.``
  [l channel f]
  (def name (string channel))
  (register! l :channels name f)
  (start! l)
  (send-now l ["SUBSCRIBE" name])
  f)

(defn psubscribe!
  ``Like `subscribe!`, for a glob pattern (`user:*:events`). Messages
  carry the :pattern that matched as well as the :channel they were
  published to.``
  [l pattern f]
  (def name (string pattern))
  (register! l :patterns name f)
  (start! l)
  (send-now l ["PSUBSCRIBE" name])
  f)

(defn- unregister! [l table- name f]
  (def arr (get (l table-) name))
  (cond
    (nil? arr) false
    (nil? f) (do (put (l table-) name nil) true)
    (do
      (def kept (filter |(not= $ f) arr))
      (if (empty? kept)
        (do (put (l table-) name nil) true)
        (do (put (l table-) name (array ;kept)) false)))))

(defn unsubscribe!
  "Remove one handler, or all of a channel's when `f` is omitted. The
  server is told only once the last handler is gone."
  [l channel &opt f]
  (def name (string channel))
  (when (unregister! l :channels name f)
    (send-now l ["UNSUBSCRIBE" name]))
  nil)

(defn punsubscribe!
  "Remove one pattern handler, or all of a pattern's."
  [l pattern &opt f]
  (def name (string pattern))
  (when (unregister! l :patterns name f)
    (send-now l ["PUNSUBSCRIBE" name]))
  nil)

(defn subscriptions
  "What is subscribed: {:channels [...] :patterns [...]}."
  [l]
  {:channels (sorted (keys (l :channels)))
   :patterns (sorted (keys (l :patterns)))})

(defn stats
  "Counters plus what is subscribed — the subscriber's health value."
  [l]
  (merge (table/clone (l :stats))
         (subscriptions l)
         {:connected (truthy? (and (l :conn) (conn/open? (l :conn))))}))
