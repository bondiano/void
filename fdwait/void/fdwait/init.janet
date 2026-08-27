### void/fdwait — "tell me when this descriptor is ready" (ADR-0011,
### SPEC.md Appendix A).
###
### A non-blocking C library owns its socket: it does the reading and
### the writing, and all it wants from the runtime is to be woken when
### the kernel has something. Janet's ev loop cannot express that from
### Janet — `ev/read` would consume bytes the library must parse
### itself — so the waiting is a two-function native module (./native),
### and this file is the Janet side of it.
###
###     (def w (fdwait/watch (PQsocket conn) :read))
###     (fdwait/wait w)          # parks the fiber, returns :read
###     (fdwait/close w)
###
### or, for the common shape of one wait per readiness:
###
###     (fdwait/ready? (PQsocket conn) :read)     # true / false
###     (fdwait/with-watcher [w fd :read] (fdwait/wait w))
###
### A watcher holds a dup() of the descriptor and normally watches ONE
### direction (see the header of src/fdwait.c for why a two-way
### watcher busy-spins on a read). :both exists for the one caller
### that genuinely wants either — a non-blocking send loop that must
### keep draining input, or it deadlocks against a server doing the
### same. A watcher is cheap but not free, so a driver that waits over
### and over on one connection keeps its watchers around — see `pair`,
### which is what void/db-postgres uses.
###
### The descriptor a library reports can change under you (libpq's
### does during a multi-host connect), hence `pair`'s `refresh`.

# Absolute, not `./native`: a relative import resolves against the
# source directory only, and the native module lives wherever it was
# built or installed (jpm's build/ tree, or the module path).
(import void/fdwait/native :as native)

(def watch
  ``(watch fd :read|:write|:both) — a watcher over a dup of `fd`.
  Closing it leaves `fd` itself open; it belongs to whoever gave it to
  us.``
  native/watch)

(def wait
  ``(wait watcher) — park this fiber until the descriptor is ready.
  Returns the direction it became ready in (:read or :write — the
  distinction is only news to a :both watcher), or :hup / :err /
  :closed when the descriptor hung up, errored, or the watcher was
  closed mid-wait. Nothing is read or written: the owning library does
  that when it wakes up.``
  native/wait)

(def close
  "(close watcher) — release the watcher's copy of the descriptor."
  native/close)

(def closed?
  "(closed? watcher) — has this watcher been closed?"
  native/closed?)

(def direction
  "(direction watcher) — :read, :write or :both."
  native/direction)

(defn ready?
  ``Did a wait end in a readiness (:read / :write) rather than in
  :hup, :err or :closed? The one predicate worth having over `wait`'s
  return value.``
  [outcome]
  (or (= :read outcome) (= :write outcome)))

(defn wait-once
  ``Wait once on a throwaway watcher, returning `wait`'s outcome.
  Convenient for a one-off; in a loop use `pair`, which does not
  allocate a watcher and an event-loop registration per wait.``
  [fd dir]
  (def w (watch fd dir))
  (defer (close w)
    (wait w)))

(defmacro with-watcher
  "Run the body with `binding` bound to a watcher over fd, closed on
  the way out (on the error path too)."
  [[binding fd dir] & body]
  ~(let [,binding (,watch ,fd ,dir)]
     (defer (,close ,binding)
       ,;body)))

# -- a long-lived pair ---------------------------------------------------

(defn pair
  ``Both directions of one descriptor, created on first use and kept
  for the life of the connection: a driver waits thousands of times on
  the same socket, and a dup() plus an event-loop registration per wait
  is a syscall pair nobody needs.

      (def p (fdwait/pair (PQsocket conn)))
      (fdwait/await p :read)
      (fdwait/refresh! p (PQsocket conn))   # the fd moved
      (fdwait/release! p)``
  [fd]
  @{:fd fd :read nil :write nil})

(defn- watcher-for [p dir]
  (or (get p dir)
      (let [w (watch (p :fd) dir)]
        (put p dir w)
        w)))

(defn await
  ``Wait on one direction of a `pair`, reusing its watcher. Same
  return values as `wait`.``
  [p dir]
  (wait (watcher-for p dir)))

(defn release!
  "Close both watchers of a pair; it can be used again afterwards."
  [p]
  (each dir [:read :write]
    (when-let [w (get p dir)]
      (close w)
      (put p dir nil)))
  p)

(defn refresh!
  ``Point a pair at a (possibly new) descriptor, dropping the watchers
  when it actually moved. libpq's socket changes while connecting to a
  multi-host cluster, and a watcher over the previous one would wait
  for an event that can no longer arrive.``
  [p fd]
  (unless (= fd (p :fd))
    (release! p)
    (put p :fd fd))
  p)
