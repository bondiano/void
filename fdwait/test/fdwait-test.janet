(import ../test-support/paths)
(import ../test-support/pipes)
(import void/fdwait :as fdwait)

# The two claims worth testing are the two the Postgres driver leans
# on: a fiber parked on a foreign descriptor really does wake when the
# descriptor becomes ready, and while it is parked the event loop is
# free for everybody else. A pipe stands in for libpq's socket — a
# descriptor janet knows nothing about, which is the whole point.

# -- watchers ------------------------------------------------------------

(def [r w] (pipes/make))

(def rw (fdwait/watch r :read))
(assert (= :read (fdwait/direction rw)) "a watcher knows its direction")
(assert (not (fdwait/closed? rw)))

(def [ok err] (protect (fdwait/watch r :sideways)))
(assert (not ok) "a direction that is not one is refused")
(assert (string/find ":read, :write or :both" err) "with the reason")

(assert (not (first (protect (fdwait/watch -1 :read))))
        "so is a descriptor that cannot be one")

# -- readiness -----------------------------------------------------------

(assert (= :write (fdwait/wait (fdwait/watch w :write)))
        "an empty pipe is writable straight away")
(assert (fdwait/ready? :write) "which is a readiness")
(each outcome [:hup :err :closed]
  (assert (not (fdwait/ready? outcome)) "and these are not"))

(var woke nil)
(var ticks 0)
(def waiter (ev/go (fn wait-for-byte [] (set woke (fdwait/wait rw)))))
(def ticker
  (ev/go (fn tick []
           # a fiber that must keep running while the waiter sleeps:
           # if the wait blocked the loop, these never happen at all
           (repeat 5 (ev/sleep 0.01) (++ ticks)))))
(ev/sleep 0.1)
(assert (nil? woke) "nothing arrived, so the waiter is still parked")
(assert (>= ticks 3) (string "and the loop kept running the whole time, got " ticks))

(pipes/put! w)
(ev/sleep 0.01)
(assert (= :read woke) "the byte woke the waiter, in the direction it arrived")
(assert (= "x" (pipes/take! r)) "which read it itself — fdwait never touches the descriptor")

# -- the watcher owns a copy, not the descriptor -------------------------

(fdwait/close rw)
(assert (fdwait/closed? rw))
(fdwait/close rw)
(assert (fdwait/closed? rw) "closing twice is fine")
(pipes/put! w)
(assert (= "x" (pipes/take! r))
        "the pipe outlived its watcher — a watcher holds a dup(), not the fd")

# a wait on a closed watcher is a mistake, not a hang
(assert (not (first (protect (fdwait/wait rw)))) "waiting on a closed watcher throws")

# closing one *during* a wait wakes the waiter instead of stranding it
(def live (fdwait/watch r :read))
(var interrupted nil)
(ev/go (fn [] (set interrupted (fdwait/wait live))))
(ev/sleep 0.01)
(fdwait/close live)
(ev/sleep 0.01)
(assert (= :closed interrupted) "a closed watcher wakes its waiter with :closed")

# -- concurrency ---------------------------------------------------------

# eight descriptors, each fed after the same delay, all waited on from
# one OS thread: the wall clock says whether they really waited at the
# same time. This is the shape of "3 x pg_sleep(1) in 1.00s" from the
# prototype, minus Postgres.
(def pipes-n 8)
(def delay 0.1)
(def ps (seq [_ :range [0 pipes-n]] (pipes/make)))
(def results @[])
(def t0 (os/clock :monotonic))
(def waiters
  (seq [[pr _] :in ps]
    (ev/go (fn [] (array/push results (fdwait/wait-once pr :read))))))
(ev/sleep delay)
(each [_ pw] ps (pipes/put! pw))
(ev/sleep 0.05)
(def elapsed (- (os/clock :monotonic) t0))

(assert (= pipes-n (length results)) "every waiter woke")
(assert (all |(= :read $) results) "and every one of them with a readiness")
(assert (< elapsed (* 3 delay))
        (string/format "%d waits concurrent, not serialized (%.3fs)" pipes-n elapsed))

(each [pr pw] ps (pipes/close! pr) (pipes/close! pw))

# -- a pair reused across waits ------------------------------------------

(def p (fdwait/pair r))
(pipes/put! w)
(assert (= :read (fdwait/await p :read)) "a pair waits like a watcher")
(pipes/take! r)
(def first-watcher (p :read))
(pipes/put! w)
(assert (= :read (fdwait/await p :read)))
(assert (= first-watcher (p :read))
        "and reuses the same watcher — no dup() per wait")
(pipes/take! r)

(fdwait/refresh! p r)
(assert (= first-watcher (p :read)) "refreshing to the same fd keeps the watchers")

(def [r2 w2] (pipes/make))
(fdwait/refresh! p r2)
(assert (nil? (p :read)) "a moved descriptor drops them")
(assert (fdwait/closed? first-watcher) "and closes the stale one")
(pipes/put! w2)
(assert (= :read (fdwait/await p :read)) "the pair now watches the new descriptor")

# -- :both, for a caller that can make progress either way ---------------

# an empty pipe is writable, and that is what a :both watcher reports
# first — the busy-spin the one-directional watchers exist to avoid,
# and exactly right for a send loop that wants whichever half moves
(def either (fdwait/watch w2 :both))
(assert (= :both (fdwait/direction either)))
(assert (= :write (fdwait/wait either)) ":both reports the writable half")
(fdwait/close either)

(def either-r (fdwait/watch r2 :both))
(pipes/put! w2)
(assert (= :read (fdwait/wait either-r))
        "and the readable one when there is nothing to write to")
(pipes/take! r2)
(fdwait/close either-r)

(fdwait/release! p)
(assert (nil? (p :read)) "release! empties it")

(each fd [r w r2 w2] (pipes/close! fd))

(print "fdwait: ok")
