### void/redis/pool — the connection pool of :redis/client, over
### void/core/pool.
###
### The mechanics — lazy connections up to :size, a checkout that
### parks the fiber with a deadline, FIFO handoff to the oldest waiter,
### rehoming a connection handed to a cancelled waiter, the counters
### void/obs exports — are void/core/pool's, shared with void/db. This
### module is what the kernel needs to know about a redis connection.
###
### Why a pool at all, when redis is single-threaded and one connection
### can carry every command? Because a fiber that sends a command has
### to wait for the reply before another fiber may use that connection
### — replies are ordered, not addressed — so a single connection makes
### every fiber queue behind the slowest one. The pool is what lets N
### fibers have N round trips in the air. It is also why the default
### size is small: eight connections is plenty of overlap for a
### sub-millisecond server, and a hundred idle connections are a
### hundred client buffers redis pays for.
###
### Two things this adapter tells the kernel that void/db's does not.
### A connection taken from the idle stack may have been closed by the
### server while it sat there (redis `timeout`, a restart, a proxy) — a
### checkout notices and reconnects before handing it over, which is
### the whole reason `conn/reconnect!` keeps the connection's identity.
### And a connection comes back reusable only when it is `conn/clean?`:
### a checkout cancelled mid-reply or abandoned inside a MULTI must not
### hand the next owner a crime scene.

(import void/core/errors :as errors)
(import void/core/log :as log)
(import void/core/pool :as cpool)
(import ./conn :as conn)

(def log-ns "void.redis.pool")

(errors/define! :void.redis/pool-timeout
  {:status 503 :doc "no connection became free within [:redis :pool :checkout-timeout]"})

(defn- open-conn
  "Open a connection for a checkout. `:fresh` marks it as opened for
  this very checkout: a failure on it is the server being unreachable,
  not a socket that went stale in the idle stack, and ./state tells the
  two apart before it retries anything."
  [conn-opts]
  (def c (conn/open conn-opts))
  (put c :fresh true)
  c)

(defn- revive
  ``An idle connection, checked before it is handed over. A server-side
  idle timeout or a restart leaves a socket that looks fine until the
  first command fails on it, and a client that noticed only then would
  fail one request per pooled connection after every redis restart.
  Returns the connection; a reconnect that fails throws, and the kernel
  closes the connection before the error reaches the caller.``
  [pool c]
  (put c :fresh false)
  (unless (conn/open? c)
    (cpool/note! pool :reconnects 1)
    (conn/reconnect! c)
    (log/debug "reopened a connection the server had closed" :ns log-ns
               :id (c :id) :generation (c :generation)))
  c)

(defn- reusable?
  "May this connection serve the next owner: not discarded, open, and
  with its protocol state known-good (`conn/clean?`)?"
  [c]
  (and (not (c :discard)) (conn/open? c) (conn/clean? c)))

(defn make
  ``Build a pool over connection options: opts {:size 8
  :checkout-timeout 5}, `conn-opts` as ./conn takes them.``
  [conn-opts &opt opts]
  (default opts {})
  # the validate hook counts reconnects on the pool it serves, hence
  # the binding it closes over
  (var pool nil)
  (set pool
       (cpool/make
         {:name "redis"
          :size (get opts :size 8)
          :checkout-timeout (get opts :checkout-timeout 5)
          :timeout-kind :void.redis/pool-timeout
          :counters {:commands 0 :command-us 0 :reconnects 0}
          :connect (fn connect [] (open-conn conn-opts))
          :close conn/close
          :validate (fn validate [c] (revive pool c))
          :reusable? reusable?}))
  pool)

(defn note-command!
  "Record one executed command (called by the instrumented execution
  path in ./state)."
  [pool us]
  (cpool/note! pool :commands 1 :command-us us))

(def checkout
  "Take a connection — see void/core/pool `acquire`: an idle one
  (reopened if the server closed it), a fresh one while under :size,
  else park until a checkin hands one over. Raises
  :void.redis/pool-timeout when none frees up within :checkout-timeout."
  cpool/acquire)

(def checkin
  "Return a connection — see void/core/pool `release`. One that is
  discarded, broken or not `conn/clean?` is closed, not reused."
  cpool/release)

(defn discard!
  "Mark a connection broken: the next checkin closes it instead of
  reusing it. A connection whose reply stream desynchronised is worse
  than no connection at all."
  [c]
  (put c :discard true)
  nil)

(def close-all!
  "Close the pool: no more checkouts, idle connections closed now,
  in-use ones closed as they come back."
  cpool/close!)

(def stats
  "Point-in-time counters: {:size :created :in-use :idle :waiting
  :checkouts :waits :wait-us :timeouts :commands :command-us
  :reconnects}."
  cpool/stats)

(def health
  "The :redis/client component health value."
  cpool/health)
