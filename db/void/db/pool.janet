### void/db/pool — the connection pool of :db/pool, over void/core/pool.
###
### One pool per :db/pool component, fed by the configured
### :void/db-driver. The mechanics — lazy connections up to :size, a
### checkout that parks the fiber with a deadline, FIFO handoff to the
### oldest waiter, rehoming a connection handed to a cancelled waiter,
### the counters void/obs exports — are void/core/pool's. This module
### is what the kernel needs to know about a database connection:
### how the driver opens and closes one, that a connection the driver
### reports as left mid-protocol (`:reusable?` — a cancelled query, an
### undrained result stream) is closed rather than handed to the next
### owner to read the previous one's result, and that an entry wraps
### the raw connection with a per-connection prepared-statement cache.
###
### The dyn side (checkout into :void.db/conn, auto-return) lives in
### ./state — this module is the adapter plus the query counters
### (:queries, :query-us) the execution funnel reports through
### `note-query!`.

(import void/core/errors :as errors)
(import void/core/pool :as cpool)
(import ./driver :as driver)

(defn- open-entry
  "Open a driver connection into a pool entry {:conn :stmts :id}. A
  driver's connect failure becomes a :void.db/connection envelope."
  [drv id]
  (def [ok conn] (protect ((drv :connect))))
  (unless ok
    (def cause (driver/wrap-error conn))
    (errors/raise :void.db/connection
                  (string "db driver connect failed: " (errors/message cause))
                  {:cause cause}))
  @{:conn conn :stmts @{} :id id})

(def default-validate-after
  ``Seconds a connection may sit idle before the pool asks the driver
  whether it is still there. The other end can close one while it
  sits — a server's idle timeout (MySQL's `wait_timeout` is eight
  hours by default, a pooler's is minutes), a proxy, a restart — and a
  dead connection handed out is an error in a caller that did nothing
  wrong.

  A busy pool never pays for this: its connections come back and go
  out again inside the window. An idle one pays one round trip on the
  first checkout after a quiet minute, which is the cheapest half of
  the trade.``
  30)

(defn make
  ``Build a pool over a driver: opts {:size 10 :checkout-timeout 5
  :validate-after 30}. `:validate-after` may be false, which is "never
  ask" — and is what a driver with no :ping gets anyway.``
  [driver &opt opts]
  (default opts {})
  (var next-id 0)
  (def ping (get driver :ping))
  (def validate-after (get opts :validate-after default-validate-after))
  (def pool
    (cpool/make
      {:name "db"
       :size (get opts :size 10)
       :checkout-timeout (get opts :checkout-timeout 5)
       # asked of an *idle* connection before it goes out, and only of
       # one that has been idle a while: false closes it and the
       # checkout decides again, which is how a connection the server
       # dropped while nobody was looking becomes a fresh one instead
       # of somebody's error
       :validate (when (and ping (number? validate-after))
                   (fn entry-alive? [entry]
                     (or (< (- (os/clock :monotonic) (get entry :idle-at 0))
                            validate-after)
                         (let [[ok alive] (protect (ping (entry :conn)))]
                           (and ok alive)))))
       :timeout-kind :void.db/pool-timeout
       :counters {:queries 0 :query-us 0}
       :connect (fn connect-entry [] (open-entry driver (++ next-id)))
       :close (fn close-entry [entry] ((driver :close) (entry :conn)))
       # asked at every checkin, on every path — a normal return, an
       # error, a fiber cancelled mid-query: a discarded entry, or one
       # the driver reports left mid-protocol, is closed
       :reusable? (fn entry-reusable? [entry]
                    (and (not (entry :discard))
                         (driver/reusable? driver (entry :conn))))}))
  (put pool :driver driver))

(defn driver-of
  "The driver a pool runs on."
  [pool]
  (pool :driver))

(defn note-query!
  "Record one executed statement (called by the instrumented execution
  path in ./state)."
  [pool us]
  (cpool/note! pool :queries 1 :query-us us))

(def checkout
  "Take a connection entry — see void/core/pool `acquire`. Raises
  :void.db/pool-timeout when none frees up within :checkout-timeout."
  cpool/acquire)

(defn checkin
  ``Return an entry — see void/core/pool `release`. A discarded entry,
  or one whose connection the driver reports non-reusable, is closed.
  The idle stamp is written here, which is the only place that knows
  when this connection stopped being used (see `make`'s :validate).``
  [pool entry]
  (put entry :idle-at (os/clock :monotonic))
  (cpool/release pool entry))

(defn discard!
  "Mark an entry broken: the next checkin closes the raw connection
  instead of reusing it (a failed ROLLBACK leaves the connection in an
  unknown state)."
  [entry]
  (put entry :discard true)
  nil)

(def close-all!
  "Close the pool: no more checkouts, idle connections closed now,
  in-use ones closed as they come back."
  cpool/close!)

(def stats
  "Point-in-time counters: {:size :created :in-use :idle :waiting
  :checkouts :waits :wait-us :timeouts :queries :query-us}."
  cpool/stats)

(def health
  "The :db/pool component health value."
  cpool/health)
