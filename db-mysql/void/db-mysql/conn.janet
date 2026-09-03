### void/db-mysql/conn — one connection, seen from the ev loop.
###
### ./worker is the thread that owns the MYSQL*. This is the half that
### talks to it: `open` starts the thread and waits for it to say
### whether it connected, and every call after that is one command on
### the request channel and one answer off the response channel. A
### fiber issuing a query parks in `ev/take` — which is the entire
### point of the arrangement, since parking is what a fiber is allowed
### to do and blocking in C is not.
###
### Three things this file is responsible for that the worker cannot
### be:
###
###   * **The thread dying.** A worker that crashes — an ffi call that
###     kills its VM, a `serve` that returns — would leave every future
###     `ev/take` parked forever, which is the worst failure a pool can
###     have because it never times out. So the thread runs under a
###     supervisor, and the supervisor channel IS the answer channel:
###     one `ev/take` sees either the answer or the death notice.
###
###     One channel and not two because `ev/select` (janet 1.41)
###     delivers from at most one *threaded* channel — given two, it
###     waits on one and never hears the other, which is the hang this
###     was supposed to prevent. Multiplexing needs the two kinds of
###     message to be distinguishable instead, which is what the
###     worker's `:answer`/`:failed` tags are for: janet's own
###     supervisor messages are `[:ok chan fiber]` and `[:error msg
###     fiber]`, and anything on the channel that is not an
###     `:answer`/`:failed` pair is therefore the thread, not a reply.
###   * **One caller at a time.** The channels carry no request ids,
###     so two fibers on one connection would read each other's
###     answers. void/db's pool hands a connection to one fiber at a
###     time and `db/with-tx` keeps it, so this cannot happen through
###     the front door — `:busy` is here to make going around the back
###     an error rather than a silently swapped result set.
###   * **Turning the worker's error dictionary back into an error.**
###     It crosses the channel as data (it has to), and callers expect
###     to `try` around a failing statement like any other.

(import ./config :as config)
(import ./worker :as worker)

# -- errors --------------------------------------------------------------

(defn- error-text [e]
  (def parts @[(get e :message "mysql: the server reported an error")])
  (when-let [c (get e :code)] (unless (zero? c) (array/push parts (string "(errno " c ")"))))
  (when-let [s (get e :sqlstate)]
    (unless (or (empty? s) (= "00000" s)) (array/push parts (string "[" s "]"))))
  (string/join parts " "))

(defn- raise
  ``Re-raise the worker's error dictionary on this side. The message
  is what a caller sees; the dictionary travels on it so
  `error-info` can answer "was that a duplicate key" without anyone
  parsing English.``
  [e]
  (error (error-text e)))

(var- error-details
  "The last error dictionary raised, by its message. A weak map would
  be better and janet has none; one entry is enough, because the only
  caller reads it in the handler of the error just raised."
  nil)

(defn- remember-error [e]
  (set error-details [(error-text e) e])
  nil)

(defn error-info
  ``The structured form of the error `e` — {:message :code :sqlstate
  :lost :context} — or nil when `e` did not come from this driver.
  `sqlstate` and `code` are what a caller branches on:

      (try (repo/create! ...)
        ([err] (if (= 1062 (get (mysql/error-info err) :code))
                 :duplicate
                 (propagate err))))``
  [e]
  (when (and error-details (= (string e) (first error-details)))
    (last error-details)))

(defn sqlstate
  "The SQLSTATE of a driver error, or nil."
  [e]
  (get (error-info e) :sqlstate))

(defn errno
  "The MySQL error number of a driver error, or nil."
  [e]
  (get (error-info e) :code))

# -- the handle ----------------------------------------------------------

(defn- start-thread [spec]
  (def h @{:spec spec
           :req (ev/thread-chan 1)
           # room for an answer and the supervisor's parting message
           # behind it, so a worker that finishes never blocks on its
           # own last give
           :resp (ev/thread-chan 4)
           :busy false
           # true from a request being sent until its reply is consumed;
           # a cancel between the two leaves it set, marking the reply
           # still on the wire so the connection is not reused (reusable?)
           :pending false
           :open false
           :closed false
           :in-tx false
           :info nil})
  # the answer channel is also the supervisor — see the header
  (ev/thread worker/serve [(h :req) (h :resp) spec] :nt (h :resp))
  h)

(defn- supervisor-message
  ``Did this come from the thread rather than from the worker's own
  protocol? Janet's supervisor messages are triples tagged :ok or
  :error; the worker answers in `:answer`/`:failed` pairs, so
  everything else on the channel is the thread reporting that it is
  no longer running.``
  [m]
  (not (and (indexed? m) (= 2 (length m))
            (or (= :answer (first m)) (= :failed (first m))))))

(defn- await
  "The worker's next answer, or an error saying the thread is gone."
  [h what]
  (def message (ev/take (h :resp)))
  # the response is off the channel now, so the channel is drained even
  # if we are about to raise a query error below. A cancel parks at the
  # ev/take above and never reaches here, leaving :pending set so the
  # connection — with the worker's reply still to come — is discarded
  # rather than pooled for the next owner to read (see `reusable?`)
  (put h :pending false)
  (cond
    (nil? message)
    (do (put h :open false)
        (errorf "mysql: the connection's worker channel closed while %s" what))

    (supervisor-message message)
    (do (put h :open false)
        (errorf "mysql: the connection's worker thread ended while %s (%s)"
                what
                (if (and (indexed? message) (= :error (first message)))
                  (string (get message 1))
                  "it exited")))

    (let [[status payload] message]
      (if (= :answer status)
        payload
        (do (remember-error payload)
            (put h :open (not (get payload :lost)))
            (raise payload))))))

(defn- ask
  "Send one command and wait for its answer."
  [h command what]
  (unless (h :open)
    (errorf "mysql: this connection is closed (%s)" what))
  (when (h :pending)
    (errorf (string "mysql: a previous statement's reply is still outstanding "
                    "on this connection (%s) — it was abandoned mid-query (a "
                    "cancel); the connection must be discarded, not reused")
            what))
  (when (h :busy)
    (errorf (string "mysql: two fibers used one connection at once (%s) — a "
                    "connection is checked out to one fiber, and a query "
                    "started inside `db/with-conn` or `db/with-tx` has to "
                    "finish there")
            what))
  (put h :busy true)
  # a request is outstanding from the give until await consumes its
  # reply; set before the give so a cancel anywhere after it leaves
  # :pending set (await clears it once the reply is off the channel)
  (put h :pending true)
  (defer (put h :busy false)
    (ev/give (h :req) command)
    (await h what)))

(defn open
  ``Start a worker thread, connect, and return the handle. Blocks the
  calling fiber (not the loop) until the server has answered the
  handshake, so a wrong host or a refused password is an error here
  rather than on the first query.``
  [spec]
  (def h (start-thread spec))
  (def info (await h "connecting"))
  (put h :open true)
  (put h :info info)
  h)

(defn open-config
  "The same, from a [:db-mysql] config slice."
  [cfg]
  (open (config/spec cfg)))

(defn live?
  "Is this handle's worker still holding a usable connection?"
  [h]
  (truthy? (h :open)))

(defn reusable?
  ``Safe to return to the pool? Not while a reply is still outstanding —
  a query abandoned mid-flight (a cancel) leaves the worker's answer on
  the channel, and the next owner's `ev/take` would read it.``
  [h]
  (and (truthy? (h :open)) (not (h :pending))))

(defn close
  ``Close the connection and end its thread. Safe twice, and safe on a
  handle whose worker has already died — a close that raised would
  turn every failure into two.

  Keyed on `:closed` and not on `:open`, and that distinction is a
  leak: a connection whose *session* died is not open any more, but
  its worker thread is still parked on the request channel waiting to
  be told something. Skipping the close for those would strand one OS
  thread per lost connection — and `driver/reconnect!` closes exactly
  those, once per server restart, per pooled connection.``
  [h]
  (unless (h :closed)
    (put h :closed true)
    (put h :open false)
    (put h :busy false)
    (protect (ev/give (h :req) [:close]))
    # the close acknowledgement, or — if the thread is already gone —
    # the supervisor's notice. Either ends the wait; both are dropped,
    # and the channels with them
    (protect (ev/take (h :resp))))
  nil)

# -- statements ----------------------------------------------------------

(defn execute
  ``Run one statement and return {:rows [...] :count n}, plus
  :insert-id for a write. Parameters are the builder's — `?`
  placeholders, values out of band here and rendered into literals on
  the far side (./types explains why, decides it).``
  [h sql &opt params opts]
  (ask h [:execute (string sql) (or params []) (or opts {})]
       (string/format "running %s" (string/slice (string sql) 0 (min 120 (length (string sql)))))))

(defn ping
  "Is the server still there? Cheap, and the only thing that finds a
  connection the server closed while it was idle in the pool."
  [h]
  (ask h [:ping] "pinging"))

(defn info
  ``What this connection is: {:server :server-version :client :library
  :host :charset :thread-id}. Read once at connect and cached — every
  value in it is fixed for the life of a session.``
  [h]
  (or (h :info) (put h :info (ask h [:info] "reading the server info"))))

(defn server-version
  "The server's version as [major minor patch]."
  [h]
  (get (info h) :server-version))
