### void/bus-db — the message log, the cursors and the transactional
### outbox, in the application's own database (SPEC.md §5.22,
### ADR-0012).
###
### The piece of void/bus that needs void/db, kept a separate plugin so
### an application whose messages never leave the process never loads a
### database driver — exactly what void/cache-redis is to void/cache
### and void/jobs-db is to void/jobs. Add it and say which backend you
### mean:
###
###     (void/run! {:plugins [:void/db :void/db-postgres
###                           :void/bus :void/bus-db ...]})
###     # config/prod.janet
###     {:bus {:backend :db :group :billing}}
###
### It brings two things that the in-process backend cannot have at
### all: a log that survives the process, and an outbox that is in the
### **same transaction** as the write it announces.
###
### Five decisions worth stating.
###
### **A message is a row in an append-only log, and a consumer group
### is a cursor into it.** Not a queue whose rows are deleted as they
### are read: fan-out is the whole difference between a bus and a
### queue, and two services must both see `:order/paid` without either
### one taking it away from the other. So `void_bus_messages` is
### written once and read by everyone, `void_bus_cursors` holds one
### position per group, and adding a consumer is adding a row — never a
### migration and never a change at the publisher.
###
### **One reader per group at a time, by lease.** A group is claimed
### with a token and a deadline in `void_bus_leases`; the holder reads
### a batch, delivers it and advances the cursor. Two processes of the
### same service therefore do not double-deliver, and a process that
### dies holding the lease costs the group one `[:bus-db :lease-ttl]`
### of latency rather than a lost cursor. This is deliberately *not*
### `FOR UPDATE SKIP LOCKED`: the row would have to stay locked for as
### long as a handler runs, which means a transaction open across
### arbitrary application code, which is the thing void/db exists to
### keep from happening by accident (ADR-0009).
###
### **A failed delivery stops the group's cursor.** Ordering per group
### is a promise (`:ordering :per-group`), and a promise that skips the
### message it could not deliver is not one. So the cursor stays,
### `stuck_attempts` counts up, the message comes back with its
### `:redelivery` set — and the poison middleware is what eventually
### takes it out of the way, by publishing it somewhere else and
### acking. Without that middleware a group blocks on a message it
### cannot handle, which is visible in `void bus cursors` and is the
### behaviour to want: at-least-once and in order means the message
### does not silently vanish.
###
### **Postgres is woken by NOTIFY; everything else polls.** The
### wake-up is `pg_notify` issued *on the connection that inserted*,
### so it is delivered on COMMIT and not at all on a rollback — which
### is exactly what makes it safe to pair with the write it announces.
### Listening happens on `void/db-postgres`'s own listener component,
### reached the public way (`require`, nil when that package is not
### here) rather than by an import, so this plugin works on sqlite with
### no Postgres on the module path. Without a listener the loop wakes
### every `[:bus-db :poll-interval]`, which is a latency floor and not
### a correctness one.
###
### **The outbox is a second table on purpose.** Publishing with this
### backend is itself an insert, so `publish-tx!` *could* write
### straight into the log and be done. It does not, because the outbox
### has to work the same way when the backend is Kafka — the forwarder
### is the seam where "committed in my database" becomes "published to
### something else", and a pattern that exists only when the two happen
### to be the same database is not the pattern ADR-0012 asked for.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/db :as db)
(import void/db/builder :as builder)
(import ./backend :as bus-backend)
(import ./state :as state)

(def log-ns "void.bus.db")

(def Config
  "Schema of the [:bus-db] config slice."
  {:table [:optional :string]
   :auto-create [:optional :boolean]
   :poll-interval [:optional [:number {:min 0.001}]]
   :batch [:optional [:int {:min 1}]]
   :lease-ttl [:optional [:number {:min 1}]]
   # how long a group waits before trying the message it is stuck on
   # again, multiplied by the number of attempts and capped
   :stuck-interval [:optional [:number {:min 0.001}]]
   :stuck-max [:optional [:number {:min 0.001}]]
   # how long a delivered message is kept before the pruner drops it.
   # :none keeps the whole log, which an application with an audit
   # requirement chooses deliberately
   :keep-for [:optional [:or [:number {:min 0}] [:enum :none]]]
   :prune-interval [:optional [:number {:min 1}]]
   :notify [:optional :boolean]
   :channel [:optional :string]
   :forwarder [:optional {:enabled [:optional :boolean]
                          :interval [:optional [:number {:min 0.001}]]
                          :batch [:optional [:int {:min 1}]]
                          :lease-ttl [:optional [:number {:min 1}]]}]})

(def defaults
  "Defaults of the [:bus-db] slice."
  {:table "void_bus"
   :auto-create true
   :poll-interval 1
   :batch 100
   :lease-ttl 30
   :stuck-interval 1
   :stuck-max 30
   :keep-for (* 7 24 3600)
   :prune-interval 300
   :notify true
   :channel "void_bus"
   :forwarder {:enabled true :interval 0.5 :batch 100 :lease-ttl 30}})

(defn- slice [cfg0]
  (def cfg (merge @{} defaults (or cfg0 {})))
  (put cfg :forwarder (merge @{} (defaults :forwarder) (get (or cfg0 {}) :forwarder {})))
  cfg)

# -- the schema ----------------------------------------------------------

(defn- seq-column [dialect]
  ``The monotonic column a cursor is a position in. The one piece of
  DDL that cannot be dialect-neutral, and the reason it is worth the
  branch: a cursor needs an ordering that a second inserter cannot
  wedge itself into, and "the id, which happens to sort" is not that
  once two processes publish in the same second.``
  (case dialect
    :postgres "bigserial primary key"
    :sqlite "integer primary key autoincrement"
    (errorf "void/bus-db has no message-log DDL for the %q dialect — the log needs a monotonic sequence column, and how to declare one is the one thing SQL does not agree on"
            dialect)))

(defn ddl
  ``Every statement that creates the tables this backend needs, as a
  tuple of SQL strings — what `[:bus-db :auto-create]` runs at boot
  and what `void bus-db ddl` prints for a deployment that would rather
  run its own migration.``
  [dialect &opt table]
  (default table (defaults :table))
  (def messages table)
  (def cursors (string table "_cursors"))
  (def leases (string table "_leases"))
  (def outbox (string table "_outbox"))
  [(string "CREATE TABLE IF NOT EXISTS " messages " (\n"
           "  seq " (seq-column dialect) ",\n"
           "  id text not null,\n"
           "  topic text not null,\n"
           "  body text,\n"
           "  meta text,\n"
           "  published_at double precision not null\n)")
   (string "CREATE UNIQUE INDEX IF NOT EXISTS " messages "_id_idx ON " messages " (id)")
   (string "CREATE INDEX IF NOT EXISTS " messages "_topic_idx ON " messages " (topic, seq)")
   (string "CREATE TABLE IF NOT EXISTS " cursors " (\n"
           "  group_name text primary key,\n"
           "  position bigint not null,\n"
           "  stuck_seq bigint,\n"
           "  stuck_attempts integer not null,\n"
           "  updated_at double precision not null\n)")
   (string "CREATE TABLE IF NOT EXISTS " leases " (\n"
           "  name text primary key,\n"
           "  token text not null,\n"
           "  until double precision not null\n)")
   (string "CREATE TABLE IF NOT EXISTS " outbox " (\n"
           "  id text primary key,\n"
           "  topic text not null,\n"
           "  body text,\n"
           "  meta text,\n"
           "  created_at double precision not null,\n"
           "  forwarded_at double precision\n)")
   # partial, so the forwarder's read touches only what it still owes:
   # the index is the size of the backlog, not of the history
   (string "CREATE INDEX IF NOT EXISTS " outbox "_pending_idx ON " outbox
           " (created_at) WHERE forwarded_at IS NULL")])

(defn create-tables!
  "Run `ddl` — idempotent, and safe to run at every boot."
  [&opt table]
  (each sql (ddl ((db/current-driver) :dialect) table)
    (db/execute-sql sql [] {:kind :write :prepared false}))
  nil)

# -- statement helpers ---------------------------------------------------

(defn- ph
  "The dialect's placeholder for parameter `n` (1-based): `?` on
  sqlite, `$n` on Postgres."
  [n]
  (((builder/dialect ((db/current-driver) :dialect)) :placeholder) n))

(defn- phs
  "`n` placeholders from `start`, comma separated."
  [start n]
  (string/join (seq [i :range [0 n]] (ph (+ start i))) ", "))

(defn- postgres? []
  (= :postgres ((db/current-driver) :dialect)))

(defn- as-text
  ``A codec's output as something a text column can hold. Every codec
  void ships produces a string; a contributed one may hand back a
  buffer, which void/db-postgres would bind as a *binary* parameter
  and store hex-escaped. A codec whose output is not text at all —
  protobuf, once void/proto exists — needs a backend with a binary
  column, and this is where that will be noticed.``
  [v]
  (if (buffer? v) (string v) v))

(defn- token []
  (string/join (seq [b :in (os/cryptorand 8)] (string/format "%02x" b))))

# -- the LISTEN/NOTIFY seam ----------------------------------------------

(defn- module-fn
  "The public binding `name` of module `path`, or nil when that
  package is not on this process's module path."
  [path name]
  (def [ok env] (protect (require path)))
  (when ok (get-in env [name :value])))

(defn pg-listener
  ``void/db-postgres's `subscribe!`/`unsubscribe!`, or nil. Resolved
  the public way, and nil for four different reasons that all mean the
  same thing here — the package is not installed, the plugin is not
  composed, its listener component is not running, or the driver under
  this pool is sqlite. The consumer falls back to polling in every one
  of them, because a wake-up is latency and never correctness.

  The fourth reason is why this probes rather than merely resolving:
  `subscribe!` exists as a binding whether or not there is a listener
  behind it, and a consumer that refused to start because the
  *optimisation* was unavailable would be exactly the wrong failure.``
  []
  (when (postgres?)
    (def sub (module-fn "void/db-postgres/init" 'subscribe!))
    (def unsub (module-fn "void/db-postgres/init" 'unsubscribe!))
    (when (and sub unsub)
      (def probe (fn probe-note [_] nil))
      (def [ok _] (protect (sub "void_bus_probe" probe)))
      (when ok
        (protect (unsub "void_bus_probe" probe))
        {:subscribe! sub :unsubscribe! unsub}))))

(defn- protect-listener
  "`pg-listener`, and nil rather than an error whatever goes wrong."
  []
  (def [ok l] (protect (pg-listener)))
  (if ok l
    (do (log/debug "no LISTEN/NOTIFY for the bus consumer — polling" :ns log-ns) nil)))

# -- the backend ---------------------------------------------------------

(defn store
  ``A bus backend over the running void/db pool. Nothing is captured
  but the configuration: which database, which driver and which
  dialect are read off the pool at call time, so the backend outlives
  a restart of the pool under it.``
  [opts]
  # `tbl`, not `table`: the name would shadow the constructor this
  # module builds statement maps with
  (def tbl (get opts :table (defaults :table)))
  (def cursors (string tbl "_cursors"))
  (def leases (string tbl "_leases"))
  (def outbox (string tbl "_outbox"))
  (def channel (get opts :channel (defaults :channel)))
  (def notify? (not= false (get opts :notify)))
  (def batch (get opts :batch (defaults :batch)))
  (def lease-ttl (get opts :lease-ttl (defaults :lease-ttl)))
  (def poll (get opts :poll-interval (defaults :poll-interval)))
  (def stuck-interval (get opts :stuck-interval (defaults :stuck-interval)))
  (def stuck-max (get opts :stuck-max (defaults :stuck-max)))
  (def keep-for (get opts :keep-for (defaults :keep-for)))
  (def prune-every (get opts :prune-interval (defaults :prune-interval)))
  (def subs @{})
  (def counters @{:published 0 :delivered 0 :failed 0 :pruned 0 :forwarded 0})

  (defn bump! [k &opt n] (put counters k (+ (get counters k 0) (or n 1))))

  (defn insert-message! [env now]
    # ON CONFLICT DO NOTHING, because a message id is a message: a
    # forwarder that published and died before marking its outbox row
    # republishes on its next pass, and the log is the one place that
    # can turn that duplicate back into one message. The alternative —
    # letting the unique index throw — would leave the row unmarked
    # forever, which is a stuck outbox rather than a duplicate, and
    # duplicates are the direction to fail in (./state on publish-tx!).
    # On Postgres it matters twice over: a failed statement poisons the
    # transaction it is in, and `bus/publish` is allowed inside one.
    (db/execute-sql
      (string "INSERT INTO " tbl " (id, topic, body, meta, published_at) VALUES ("
              (phs 1 5) ") ON CONFLICT (id) DO NOTHING")
      [(env :id) (string (env :topic)) (as-text (env :body))
       (as-text (env :meta-body)) now]
      {:kind :write})
    # on the same connection, so it rides the caller's transaction when
    # there is one and commits with it
    (when (and notify? (postgres?))
      (db/execute-sql "SELECT pg_notify($1, $2)" [channel (string (env :topic))]
                      {:kind :write}))
    nil)

  (defn take-lease! [name tok now ttl]
    (def n
      (db/execute-sql
        (string "UPDATE " leases " SET token = " (ph 1) ", until = " (ph 2)
                " WHERE name = " (ph 3)
                " AND (until < " (ph 4) " OR token = " (ph 5) ")")
        [tok (+ now ttl) name now tok]
        {:kind :write}))
    (if (pos? (get n :count 0))
      true
      # no row yet: the first taker inserts it, and a lost race there
      # is a unique violation, which is an answer and not an error
      (let [[ok _] (protect
                     (db/execute-sql
                       (string "INSERT INTO " leases " (name, token, until) VALUES ("
                               (phs 1 3) ")")
                       [name tok (+ now ttl)] {:kind :write}))]
        ok)))

  (defn release-lease! [name tok]
    (protect
      (db/execute-sql
        (string "UPDATE " leases " SET until = 0 WHERE name = " (ph 1)
                " AND token = " (ph 2))
        [name tok] {:kind :write}))
    nil)

  (defn cursor-of [group]
    (first (db/query-sql
             [(string "SELECT group_name, position, stuck_seq, stuck_attempts FROM "
                      cursors " WHERE group_name = " (ph 1))
              [(string group)]])))

  (defn ensure-cursor! [group now]
    (unless (cursor-of group)
      (protect
        (db/execute-sql
          (string "INSERT INTO " cursors
                  " (group_name, position, stuck_seq, stuck_attempts, updated_at) VALUES ("
                  (phs 1 5) ")")
          [(string group) 0 nil 0 now] {:kind :write})))
    nil)

  (defn save-cursor! [group position stuck-seq stuck-attempts now]
    (db/execute-sql
      (string "UPDATE " cursors " SET position = " (ph 1)
              ", stuck_seq = " (ph 2) ", stuck_attempts = " (ph 3)
              ", updated_at = " (ph 4)
              " WHERE group_name = " (ph 5))
      [position stuck-seq stuck-attempts now (string group)]
      {:kind :write})
    nil)

  (defn read-batch [position topics]
    (def exact (and topics (not (empty? topics))))
    (def params @[position])
    (def where
      (if exact
        (do
          (each t topics (array/push params (string t)))
          (string " AND topic IN (" (phs 2 (length topics)) ")"))
        ""))
    (array/push params batch)
    (db/query-sql
      [(string "SELECT seq, id, topic, body, meta, published_at FROM " tbl
               " WHERE seq > " (ph 1) where
               " ORDER BY seq LIMIT " (ph (length params)))
       (tuple ;params)]))

  (defn prune! [now]
    (when (and (number? keep-for) (pos? keep-for))
      (def low
        (get (first (db/query-sql
                      [(string "SELECT min(position) AS low FROM " cursors) []]))
             :low))
      (when low
        (def n
          (db/execute-sql
            (string "DELETE FROM " tbl " WHERE seq <= " (ph 1)
                    " AND published_at < " (ph 2))
            [low (- now keep-for)] {:kind :write}))
        (bump! :pruned (get n :count 0)))
      (db/execute-sql
        (string "DELETE FROM " outbox " WHERE forwarded_at IS NOT NULL"
                " AND forwarded_at < " (ph 1))
        [(- now keep-for)] {:kind :write}))
    nil)

  (defn row->envelope [row cur]
    (def seq (get row :seq))
    @{:id (get row :id)
      :topic (keyword (get row :topic))
      :body (get row :body)
      :meta-body (get row :meta)
      :seq seq
      :redelivery (if (= seq (get cur :stuck_seq)) (get cur :stuck_attempts 0) 0)})

  (defn drain! [sub deliver]
    ``One pass for one group: take the lease, read a batch, deliver it
    in order, advance the cursor. Returns how many messages were
    delivered — zero means "nothing to do", which is what sends the
    loop to sleep.``
    (def group (sub :group))
    (def now (os/clock :realtime))
    (if (not (take-lease! (string "consumer:" group) (sub :token) now lease-ttl))
      (do (put sub :leader false) 0)
      (do
        (put sub :leader true)
        (def cur (or (cursor-of group) {:position 0 :stuck_attempts 0}))
        (def rows (read-batch (get cur :position 0) (sub :exact-topics)))
        (var position (get cur :position 0))
        (var stuck-seq nil)
        (var stuck-attempts 0)
        (var n 0)
        (var failed false)
        (each row rows
          (unless (or failed (sub :stopped))
            (def env (row->envelope row cur))
            (def [ok err] (protect (deliver env)))
            (if ok
              (do (set position (env :seq)) (++ n) (bump! :delivered))
              (do
                (set failed true)
                (set stuck-seq (env :seq))
                (set stuck-attempts (inc (env :redelivery)))
                (bump! :failed)
                (log/warn "bus delivery failed, the group's cursor holds"
                          :ns log-ns :group group
                          :topic (env :topic) :id (env :id)
                          :seq (env :seq) :redelivery (env :redelivery)
                          :err (if (string? err) err (describe err)))))))
        (when (or (not= position (get cur :position 0))
                  (not= stuck-seq (get cur :stuck_seq))
                  (not= stuck-attempts (get cur :stuck_attempts 0)))
          (save-cursor! group position stuck-seq stuck-attempts now))
        (put sub :stuck stuck-seq)
        (put sub :stuck-attempts stuck-attempts)
        n)))

  {:name :db
   :encoded? true
   :guarantees {:delivery :at-least-once
                :ordering :per-group
                :durable true
                :shared true}

   :publish!
   (fn db-publish [env]
     (insert-message! env (or (get-in env [:meta :published-at]) (os/clock :realtime)))
     (bump! :published)
     1)

   :consume!
   (fn db-consume [o deliver]
     (def group (get o :group :default))
     (def sub @{:group group
                :token (token)
                :exact-topics (get o :exact-topics)
                :stopped false
                :leader false
                :wakeup (ev/chan 1)
                :done (ev/chan 1)})
     (db/with-conn (ensure-cursor! group (os/clock :realtime)))
     (def listener (when notify? (protect-listener)))
     (when listener
       (def on-note
         (fn bus-notified [_]
           (when (zero? (ev/count (sub :wakeup)))
             (protect (ev/give (sub :wakeup) true)))))
       (put sub :listener listener)
       (put sub :on-note on-note)
       ((listener :subscribe!) channel on-note)
       (log/info "bus consumer is woken by NOTIFY" :ns log-ns
                 :group group :channel channel))
     (ev/go
       (fn bus-db-consumer []
         (var last-prune (os/clock :monotonic))
         (while (not (sub :stopped))
           (def [ok n]
             (protect (db/with-conn (drain! sub deliver))))
           (unless ok
             (log/error "bus consumer pass failed" :ns log-ns
                        :group group
                        :err (if (string? n) n (describe n))))
           # a full batch means there is more waiting: come straight
           # back rather than sleeping on a backlog
           (when (or (not ok) (nil? n) (< n batch))
             # a group stuck on a message it cannot deliver has nothing
             # to be woken *by* — no publisher will announce the
             # message it already has — so it waits on its own clock
             # rather than on the poll interval, which under
             # LISTEN/NOTIFY is deliberately long
             (def wait-for
               (if (sub :stuck)
                 (min stuck-max (* stuck-interval (max 1 (sub :stuck-attempts))))
                 poll))
             (protect (ev/with-deadline wait-for (ev/take (sub :wakeup)))))
           (when (> (- (os/clock :monotonic) last-prune) prune-every)
             (set last-prune (os/clock :monotonic))
             (when (sub :leader)
               (protect (db/with-conn (prune! (os/clock :realtime)))))))
         (protect (release-lease! (string "consumer:" group) (sub :token)))
         (ev/give (sub :done) true)))
     (put subs group sub)
     sub)

   :stop!
   (fn db-stop [sub]
     (unless (sub :stopped)
       (put sub :stopped true)
       (when-let [l (sub :listener)]
         (protect ((l :unsubscribe!) channel (sub :on-note))))
       (protect (ev/give (sub :wakeup) true))
       (def [ok _] (protect (ev/with-deadline 10 (ev/take (sub :done)))))
       (unless ok
         (log/warn "bus consumer did not stop within 10 s" :ns log-ns
                   :group (sub :group)))
       (put subs (sub :group) nil))
     nil)

   :close
   (fn db-close []
     (each g (keys subs)
       (when-let [sub (get subs g)] (put sub :stopped true)))
     nil)

   :stats
   (fn db-stats []
     (def [ok rows]
       (protect
         (db/query-sql
           [(string "SELECT group_name, position, stuck_seq, stuck_attempts FROM "
                    cursors " ORDER BY group_name") []])))
     (merge (table/to-struct counters)
            {:groups (sorted (keys subs))
             :cursors (if ok (map |{:group (get $ :group_name)
                                    :position (get $ :position)
                                    :stuck (get $ :stuck_seq)
                                    :attempts (get $ :stuck_attempts)}
                                  rows)
                        [])}))

   # -- the outbox, which is not part of the backend contract ----------
   #
   # The broker installs these two on itself: `publish-tx!` is the
   # writer, and the forwarder component is the reader. They are here
   # rather than in ./state because they are SQL.

   :outbox-write!
   (fn outbox-write [env]
     (unless (db/in-transaction?)
       (error "bus/publish-tx! must be called inside (db/with-tx ...) — outside one there is no transaction for the message to commit with, which is the whole of what it buys"))
     (db/execute-sql
       (string "INSERT INTO " outbox " (id, topic, body, meta, created_at, forwarded_at) VALUES ("
               (phs 1 6) ")")
       [(env :id) (string (env :topic)) (as-text (env :body))
        (as-text (env :meta-body))
        (or (get-in env [:meta :published-at]) (os/clock :realtime)) nil]
       {:kind :write})
     env)

   :outbox-pending
   (fn outbox-pending [limit]
     (db/query-sql
       [(string "SELECT id, topic, body, meta, created_at FROM " outbox
                " WHERE forwarded_at IS NULL ORDER BY created_at, id LIMIT " (ph 1))
        [limit]]))

   :outbox-mark!
   (fn outbox-mark [id now]
     (db/execute-sql
       (string "UPDATE " outbox " SET forwarded_at = " (ph 1)
               " WHERE id = " (ph 2) " AND forwarded_at IS NULL")
       [now id] {:kind :write})
     nil)

   :outbox-count
   (fn outbox-count []
     (get (first (db/query-sql
                   [(string "SELECT count(*) AS n FROM " outbox
                            " WHERE forwarded_at IS NULL") []]))
          :n 0))

   :lease! (fn lease [name tok now ttl] (take-lease! name tok now ttl))
   :counters counters})

# -- the forwarder -------------------------------------------------------

(defn forward-once!
  ``Publish every outbox row that has not been forwarded yet and mark
  it. Returns how many went out.

  The order is publish-then-mark, which is the direction that fails
  into a **duplicate** rather than into a loss: a forwarder that dies
  between the two republishes the message on its next pass, and the
  dedup middleware — or an idempotent handler, which is the contract
  anyway — absorbs it. Marking first would fail into silence.``
  [b limit]
  (def now (os/clock :realtime))
  (def rows (db/with-conn ((b :outbox-pending) limit)))
  (var n 0)
  (each row rows
    (def env @{:id (get row :id)
               :topic (keyword (get row :topic))
               :body (get row :body)
               :meta-body (get row :meta)})
    ((b :publish!) env)
    (db/with-conn ((b :outbox-mark!) (get row :id) now))
    (++ n))
  n)

(defn make-forwarder
  "The forwarder's mutable state — a fiber, a lease and its counters."
  [b cfg]
  @{:backend b
    :interval (get cfg :interval 0.5)
    :batch (get cfg :batch 100)
    :lease-ttl (get cfg :lease-ttl 30)
    :token (token)
    :stopped false
    :leader false
    :forwarded 0
    :done (ev/chan 1)})

(defn start-forwarder!
  ``Start the forwarding fiber. Only the process holding the
  `outbox` lease forwards, so a fleet of web processes all composing
  void/bus-db publishes each outbox row once — the same lease the
  consumers take, and the same reason.``
  [f]
  (def b (f :backend))
  (ev/go
    (fn bus-outbox-forwarder []
      (while (not (f :stopped))
        (def [ok res]
          (protect
            (db/with-conn
              (if ((b :lease!) "outbox" (f :token) (os/clock :realtime) (f :lease-ttl))
                (do (put f :leader true) (forward-once! b (f :batch)))
                (do (put f :leader false) 0)))))
        (if ok
          (put f :forwarded (+ (f :forwarded) (or res 0)))
          (log/error "outbox forwarder pass failed" :ns log-ns
                     :err (if (string? res) res (describe res))))
        (ev/sleep (f :interval)))
      (ev/give (f :done) true)))
  f)

(defn stop-forwarder!
  "Stop the forwarding fiber and wait for its current pass."
  [f]
  (unless (f :stopped)
    (put f :stopped true)
    (def [ok _] (protect (ev/with-deadline 10 (ev/take (f :done)))))
    (unless ok
      (log/warn "outbox forwarder did not stop within 10 s" :ns log-ns)))
  nil)

# -- the backend contribution --------------------------------------------

(var current-backend
  "The backend this process made, for the outbox CLI and the forwarder
  component."
  nil)

(plugin/contribute! :void.bus/backend
  {:name :db
   :doc "The application's own database: an append-only message log, a cursor per consumer group, at-least-once and in order, woken by LISTEN/NOTIFY on Postgres and by polling everywhere else. The backend the transactional outbox needs."
   :make (fn make-db-backend [_]
           (def cfg (slice (state/config-slice :bus-db)))
           (def b (store cfg))
           (set current-backend b)
           b)})

# -- the outbox writer, installed on the broker --------------------------

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   # before :bus/consume (800), so that a handler cannot see a broker
   # whose publish-tx! is still an error
   :phase 700
   :name :bus-db/outbox
   :doc "Install the transactional outbox writer on the broker"
   # the writer itself is the backend's, resolved at publish time
   # (void/bus/state's `outbox-writer`) — this hook is the *check*: a
   # composition that cannot keep what it publishes should say so at
   # boot rather than at the first payment
   :fn (fn check-outbox [_]
         (when-let [br state/current-broker]
           (def b (br :backend))
           (if (get b :outbox-write!)
             (do
               (bus-backend/require-durable! b "the transactional outbox")
               (log/info "transactional outbox ready" :ns log-ns))
             (log/warn "void/bus-db is composed but [:bus :backend] is not :db — bus/publish-tx! stays unavailable, because an outbox in front of a transport that forgets is a longer way to lose the message"
                       :ns log-ns :backend (b :name)))))})

# -- components ----------------------------------------------------------

(def schema-component
  (system/component :bus.db/schema
    :doc "The tables void/bus-db reads and writes. Created at :start
    when [:bus-db :auto-create] — the same bargain void/jobs-db makes:
    true in development, and a deployment that runs its own migrations
    turns it off and takes the DDL from `void bus-db ddl`."
    :deps [:db/pool]
    :config {:key :bus-db :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (when (cfg :auto-create)
        (db/with-conn (create-tables! (cfg :table))))
      (log/info "bus tables ready" :ns log-ns
                :table (cfg :table) :auto-create (cfg :auto-create))
      {:table (cfg :table) :auto-create (cfg :auto-create)})
    :health (fn health [s] (merge {:status :up} s))))

(def forwarder-component
  (system/component :bus.db/forwarder
    :doc "The half of the transactional outbox that publishes: a fiber
    that reads what `publish-tx!` committed and hands it to the
    backend, holding a lease so a fleet forwards each row once. On by
    default — an outbox nobody drains is a table that grows, and the
    failure mode of forgetting to start it is worse than the cost of
    one idle fiber."
    :deps [:bus.db/schema :void/bus]
    :config {:key :bus-db :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (slice cfg0))
      (def fcfg (cfg :forwarder))
      (def br (deps :void/bus))
      (def b (br :backend))
      (cond
        (not (get fcfg :enabled))
        (do
          (log/info "outbox forwarder not started ([:bus-db :forwarder :enabled] is false)"
                    :ns log-ns)
          @{:stopped true :disabled true})

        (not (get b :outbox-write!))
        (do
          (log/debug "outbox forwarder not started — [:bus :backend] is not :db"
                     :ns log-ns :backend (b :name))
          @{:stopped true :disabled true})

        (start-forwarder! (make-forwarder b fcfg))))
    :stop
    (fn stop [f]
      (unless (get f :disabled) (stop-forwarder! f)))
    :health
    (fn health [f]
      (if (get f :disabled)
        {:status :up :forwarder :disabled}
        {:status :up :leader (f :leader) :forwarded (f :forwarded)}))))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :bus-db/ddl
   :read-only? true
   :doc "Print the DDL of the message log, the cursors and the outbox: void bus-db ddl"
   :needs [:db/pool]
   :fn (fn cli-ddl [_ & args]
         (unless (empty? args)
           (errorf "void bus-db ddl takes no arguments (got %q)" (string/join args " ")))
         (def cfg (slice (state/config-slice :bus-db)))
         (each sql (ddl ((db/current-driver) :dialect) (cfg :table))
           (print sql ";")))})

(plugin/contribute! :void.core/cli
  {:name :bus-db/cursors
   :read-only? true
   :doc "Where each consumer group has got to: void bus-db cursors"
   :needs [:bus.db/schema :db/pool]
   :fn (fn cli-cursors [_ _pool & args]
         (unless (empty? args)
           (errorf "void bus-db cursors takes no arguments (got %q)" (string/join args " ")))
         (def cfg (slice (state/config-slice :bus-db)))
         (def tbl (cfg :table))
         (def rows
           (db/with-conn
             (db/query-sql
               [(string "SELECT group_name, position, stuck_seq, stuck_attempts FROM "
                        tbl "_cursors ORDER BY group_name") []])))
         (def head (db/with-conn
                     (get (first (db/query-sql
                                   [(string "SELECT max(seq) AS s FROM " tbl) []]))
                          :s 0)))
         (printf "log head    %q" (or head 0))
         (print)
         (if (empty? rows)
           (print "no consumer group has read anything yet")
           (do
             (printf "%-20s %10s %10s %8s" "group" "position" "behind" "stuck")
             (each r rows
               (printf "%-20s %10d %10d %8s"
                       (get r :group_name) (get r :position 0)
                       (- (or head 0) (get r :position 0))
                       (if (get r :stuck_seq)
                         (string (get r :stuck_seq) "×" (get r :stuck_attempts 0))
                         "-"))))))})

(plugin/contribute! :void.core/cli
  {:name :bus-db/outbox
   :read-only? true
   :doc "What the outbox still owes: void bus-db outbox"
   :needs [:bus.db/schema :db/pool]
   :fn (fn cli-outbox [_ _pool & args]
         (unless (empty? args)
           (errorf "void bus-db outbox takes no arguments (got %q)" (string/join args " ")))
         (unless current-backend
           (error "this process is not using the :db bus backend"))
         (def pending (db/with-conn ((current-backend :outbox-pending) 20)))
         (printf "pending     %d" (db/with-conn ((current-backend :outbox-count))))
         (unless (empty? pending)
           (print)
           (each r pending
             (printf "%s  %-24s %s"
                     (get r :id) (get r :topic)
                     (os/date (math/floor (get r :created_at 0)) true)))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/bus-db
  :doc "The bus in the application's own database: an append-only message log with a cursor per consumer group (at-least-once, ordered, woken by LISTEN/NOTIFY on Postgres), and the transactional outbox — publish-tx! writes in the caller's transaction and a forwarder publishes what committed."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/bus ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :bus-db
  :config-schema Config
  :config-defaults defaults
  :components [schema-component forwarder-component])
