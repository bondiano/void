### void/redis/pubsub — publish/subscribe on a connection of its own.
###
### A subscribed connection is not a request/response connection any
### more. In RESP2 it accepts nothing but SUBSCRIBE, UNSUBSCRIBE and
### PING, and in either protocol it may speak at any moment, without
### having been asked. That is why this cannot live on the pool: a
### pooled connection is handed to whoever asks next, and whoever asks
### next wants to run GET.
###
### So: one connection, one fiber parked in a read, and nothing else. It
### costs nothing while idle — the fiber is suspended on the ev loop, not
### spinning — and it is opened on the first subscription, so an
### application that never subscribes never opens it.
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
  {:params [(or {:keyword :any} @{:keyword :any})
            (or {:codec :any :backoff :any & r} @{:codec :any :backoff :any & r} :nil)]
   :ret @{:conn-opts :any
          :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
          :backoff @{:min :number :max :number :factor :number}
          :channels @{:any @[:any]} :patterns @{:any @[:any]}
          :conn :any :running :boolean :epoch :number :fiber :any
          :stats @{:messages :number :reconnects :number :errors :number
                   :delivered :number}
          & r}}
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
    :epoch 0
    :fiber nil
    :stats @{:messages 0 :reconnects 0 :errors 0 :delivered 0}})

# -- what the server says ------------------------------------------------

(defn- message-of
  {:params [@{:codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)} & r}
            :any]
   :ret (or {:channel :string :payload :any}
            {:pattern :string :channel :string :payload :any}
            :nil)}
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

(defn- handlers-for
  {:params [@{:patterns @{:any @[:any]} :channels @{:any @[:any]} & r}
            {:pattern :string? :channel :string? & r}]
   :ret (or @[:any] :nil)}
  "The registered handlers for a decoded message: its pattern's
  subscribers when it matched one, else its channel's."
  [l msg]
  (if-let [pattern (msg :pattern)]
    (get (l :patterns) pattern)
    (get (l :channels) (msg :channel))))

(defn- deliver
  {:params [@{:stats @{:messages :number :reconnects :number :errors :number
                       :delivered :number}
             :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
             :patterns @{:any @[:any]} :channels @{:any @[:any]}
             & r}
            :any]
   :ret :nil}
  ``Decode one frame and hand it to every handler registered for its
  channel or pattern, counting messages, deliveries and errors as it
  goes — the single place `:stats` is kept honest.``
  [l frame]
  # the decode runs on bytes some publisher chose: a payload the codec
  # cannot read is that message's problem, not the connection's — it
  # is dropped and counted, and the subscriber stays up
  (def [ok msg] (protect (message-of l frame)))
  (unless ok
    (put-in l [:stats :errors] (inc (get-in l [:stats :errors])))
    (log/error "an undecodable message was dropped" :ns log-ns
               :err (if (string? msg) msg (describe msg))))
  (when (and ok msg)
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

(defn- desired-commands
  {:params [@{:channels @{:any @[:any]} :patterns @{:any @[:any]} & r}]
   :ret @[[:any]]}
  "The SUBSCRIBE/PSUBSCRIBE commands that bring a connection up to
  date with everything currently registered — what `ensure-conn` sends
  on a fresh or reopened connection, since a socket carries no
  subscription across itself."
  [l]
  (def out @[])
  (unless (empty? (l :channels))
    (array/push out ["SUBSCRIBE" ;(sorted (keys (l :channels)))]))
  (unless (empty? (l :patterns))
    (array/push out ["PSUBSCRIBE" ;(sorted (keys (l :patterns)))]))
  out)

(defn- ensure-conn
  {:params [@{:conn :any :conn-opts :any
             :channels @{:any @[:any]} :patterns @{:any @[:any]} & r}]
   :ret :any
   :throws [:string
            {:redis/error :boolean :code :string :fatal :boolean
             :message :string :server :string}
            {:redis/error :boolean :code :string :message :string
             :reply :string :command (or :string :nil)}]}
  ``The connection, opened and brought up to date with what is
  subscribed. Reconnecting means resubscribing: a redis connection
  carries no subscription across a socket, and neither does a
  replacement for one.``
  [l]
  (def existing (l :conn))
  (if (and existing (conn/open? existing))
    existing
    (do
      (when existing (conn/close existing))
      (def c (conn/open (l :conn-opts)))
      (put l :conn c)
      (each cmd (desired-commands l) (conn/send c cmd))
      c)))

(defn- serve
  {:params [@{:running :boolean :epoch :number :conn-established :boolean
             :conn :any :conn-opts :any
             :channels @{:any @[:any]} :patterns @{:any @[:any]}
             :stats @{:messages :number :reconnects :number :errors :number
                      :delivered :number}
             :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
             & r}
            :number]
   :ret :nil
   :throws [:string
            {:redis/error :boolean :code :string :fatal :boolean
             :message :string :server :string}
            {:redis/error :boolean :code :string :message :string
             :reply :string :command (or :string :nil)}]}
  "Read frames until the connection fails, the subscriber stops, or a
  newer reader takes over."
  [l epoch]
  (def c (ensure-conn l))
  # reaching here means a connect succeeded: the next drop is a fresh
  # incident, not a continuation of the last backoff climb
  (put l :conn-established true)
  (while (and (l :running) (= epoch (l :epoch)) (conn/open? c))
    # no read timeout: a subscriber is meant to sit silent, and the
    # only thing a timeout here could mean is "nobody published"
    (deliver l (conn/receive c {:timeout conn/no-timeout}))))

(defn- backoff-seq
  {:params [@{:backoff @{:min :number :max :number :factor :number} & r}]
   :ret (fn [] :number)}
  ``A fresh reconnect-delay generator starting at `:min` and climbing
  by `:factor` toward `:max` on every call — `reader` asks for one
  each time a connect actually succeeds, which is what resets the
  climb after every real incident.``
  [l]
  (def b (l :backoff))
  (var delay (b :min))
  (fn next-delay []
    (def d delay)
    (set delay (min (b :max) (* delay (b :factor))))
    d))

(defn- reader
  {:params [@{:running :boolean :epoch :number :conn-established :boolean
             :conn :any :conn-opts :any
             :channels @{:any @[:any]} :patterns @{:any @[:any]}
             :backoff @{:min :number :max :number :factor :number}
             :stats @{:messages :number :reconnects :number :errors :number
                      :delivered :number}
             :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
             & r}
            :number]
   :ret :nil}
  ``The reading loop of one `start!`. `epoch` is which start! this is:
  a stop!/start! pair may run before a reader parked in a receive has
  observed either, and a stale reader that trusted :running alone
  would serve alongside its successor — every message delivered
  twice. A reader that finds the epoch moved on simply leaves,
  touching nothing its successor now owns.``
  [l epoch]
  (var next-delay (backoff-seq l))
  (while (and (l :running) (= epoch (l :epoch)))
    (put l :conn-established false)
    (def [ok err] (protect (serve l epoch)))
    (when (l :conn-established)
      (set next-delay (backoff-seq l)))
    (when (and (not ok) (l :running) (= epoch (l :epoch)))
      (put-in l [:stats :reconnects] (inc (get-in l [:stats :reconnects])))
      (when-let [c (l :conn)] (protect (conn/close c)) (put l :conn nil))
      (def delay (next-delay))
      (log/warn "the subscriber connection dropped — reconnecting" :ns log-ns
                :in delay
                :err (if (dictionary? err) (get err :message (describe err))
                       (describe err)))
      (ev/sleep delay)))
  (when (= epoch (l :epoch))
    (when-let [c (l :conn)]
      (protect (conn/close c))
      (put l :conn nil))))

(defn running?
  {:params [@{:running :boolean & r}] :ret :boolean :narrows :any}
  "Is the reading fiber alive?"
  [l]
  (truthy? (l :running)))

(defn start!
  {:params [@{:running :boolean :epoch :number :conn-established :boolean
             :conn :any :conn-opts :any :fiber :any
             :channels @{:any @[:any]} :patterns @{:any @[:any]}
             :backoff @{:min :number :max :number :factor :number}
             :stats @{:messages :number :reconnects :number :errors :number
                      :delivered :number}
             :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
             & r}]
   :ret @{:running :boolean :epoch :number :conn-established :boolean
          :conn :any :conn-opts :any :fiber :any
          :channels @{:any @[:any]} :patterns @{:any @[:any]}
          :backoff @{:min :number :max :number :factor :number}
          :stats @{:messages :number :reconnects :number :errors :number
                   :delivered :number}
          :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
          & r}}
  "Start the reading fiber. Idempotent; the connection still waits for
  the first subscription."
  [l]
  (unless (l :running)
    (put l :running true)
    (def epoch (inc (get l :epoch 0)))
    (put l :epoch epoch)
    (put l :fiber (ev/go (fn subscriber [] (reader l epoch)))))
  l)

(defn stop!
  {:params [@{:running :boolean :conn :any :fiber :any & r}]
   :ret @{:running :boolean :conn :any :fiber :any & r}}
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

(defn- register!
  {:params [@{:channels @{:any @[:any]} :patterns @{:any @[:any]} & r}
            :keyword :string (fn [a] :any)]
   :ret :boolean}
  ``Add `f` to the handlers recorded under `name` in `table-`
  (`:channels` or `:patterns`), creating the list if this is the first
  one. Answers true exactly when `name` is newly subscribed — the
  signal `subscribe!`/`psubscribe!` use to decide whether the server
  needs telling.``
  [l table- name f]
  (def arr (or (get (l table-) name)
               (let [a @[]] (put (l table-) name a) a)))
  (array/push arr f)
  (= 1 (length arr)))

(defn- send-now
  {:params [@{:conn :any & r} (or @[:any] [:any])] :ret :nil}
  ``Send a subscription command on the live connection, if there is
  one — and do nothing when there is not.

  The connection is opened by the reading fiber and by nothing else,
  which is what keeps two fibers from each opening one and then
  subscribing on the other's. So this is best-effort by design: the
  desired set has already been recorded, and the reader sends whatever
  it finds there when it opens or reopens the connection. Worst case
  the command is sent twice, and redis answers a repeated SUBSCRIBE
  with the same count it did the first time.``
  [l cmd]
  (when-let [c (l :conn)]
    (when (conn/open? c)
      (def [ok err] (protect (conn/send c cmd)))
      (unless ok
        (log/debug "the subscription will be sent on reconnect" :ns log-ns
                   :command (first cmd)
                   :err (if (dictionary? err) (get err :message (describe err))
                          (describe err)))))))

(defn subscribe!
  {:params [@{:running :boolean :epoch :number :conn-established :boolean
             :conn :any :conn-opts :any :fiber :any
             :channels @{:any @[:any]} :patterns @{:any @[:any]}
             :backoff @{:min :number :max :number :factor :number}
             :stats @{:messages :number :reconnects :number :errors :number
                      :delivered :number}
             :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
             & r}
            :any (fn [a] :any)]
   :ret (fn [a] :any)}
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
  {:params [@{:running :boolean :epoch :number :conn-established :boolean
             :conn :any :conn-opts :any :fiber :any
             :channels @{:any @[:any]} :patterns @{:any @[:any]}
             :backoff @{:min :number :max :number :factor :number}
             :stats @{:messages :number :reconnects :number :errors :number
                      :delivered :number}
             :codec {:name :keyword :encode (fn [a] :any) :decode (fn [a] :any)}
             & r}
            :any (fn [a] :any)]
   :ret (fn [a] :any)}
  ``Like `subscribe!`, for a glob pattern (`user:*:events`). Messages
  carry the :pattern that matched as well as the :channel they were
  published to.``
  [l pattern f]
  (def name (string pattern))
  (register! l :patterns name f)
  (start! l)
  (send-now l ["PSUBSCRIBE" name])
  f)

(defn- unregister!
  {:params [@{:channels @{:any @[:any]} :patterns @{:any @[:any]} & r}
            :keyword :string (or (fn [a] :any) :nil)]
   :ret :boolean}
  ``Remove `f` from `name`'s handlers in `table-`, or every handler
  when `f` is nil. Answers true exactly when `name` has no handlers
  left — the signal `unsubscribe!`/`punsubscribe!` use to decide
  whether the server needs telling.``
  [l table- name f]
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
  {:params [@{:channels @{:any @[:any]} :patterns @{:any @[:any]} :conn :any & r}
            :any (or (fn [a] :any) :nil)]
   :ret :nil}
  "Remove one handler, or all of a channel's when `f` is omitted. The
  server is told only once the last handler is gone."
  [l channel &opt f]
  (def name (string channel))
  (when (unregister! l :channels name f)
    (send-now l ["UNSUBSCRIBE" name]))
  nil)

(defn punsubscribe!
  {:params [@{:channels @{:any @[:any]} :patterns @{:any @[:any]} :conn :any & r}
            :any (or (fn [a] :any) :nil)]
   :ret :nil}
  "Remove one pattern handler, or all of a pattern's."
  [l pattern &opt f]
  (def name (string pattern))
  (when (unregister! l :patterns name f)
    (send-now l ["PUNSUBSCRIBE" name]))
  nil)

(defn subscriptions
  {:params [@{:channels @{:any @[:any]} :patterns @{:any @[:any]} & r}]
   :ret {:channels @[:any] :patterns @[:any]}}
  "What is subscribed: {:channels [...] :patterns [...]}."
  [l]
  {:channels (sorted (keys (l :channels)))
   :patterns (sorted (keys (l :patterns)))})

(defn stats
  {:params [@{:stats @{:messages :number :reconnects :number :errors :number
                       :delivered :number}
             :channels @{:any @[:any]} :patterns @{:any @[:any]} :conn :any & r}]
   :ret @{:messages :number :reconnects :number :errors :number :delivered :number
          :channels @[:any] :patterns @[:any] :connected :boolean}}
  "Counters plus what is subscribed — the subscriber's health value."
  [l]
  (merge (table/clone (l :stats))
         (subscriptions l)
         {:connected (truthy? (and (l :conn) (conn/open? (l :conn))))}))
