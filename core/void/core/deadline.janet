### void/core/deadline — a task under a deadline.
###
### `ev/with-deadline` is the wrong tool for a request fiber: it puts
### the deadline on the *root task*, and cancelling a long-lived fiber
### in the middle of an ev operation is the upstream bug class of
### janet-lang/janet#1337 and #1707 — the connection loop, the worker
### loop or the request itself dies with the work it was timing. The
### idiom every package arrived at instead is the same one: run the
### work as its own supervised child task, put `ev/deadline` on *that*,
### and read the outcome off the supervisor channel.
###
### It had been written twelve times (http/server, http/client, grpc,
### the two pools, three connect paths, four waits in void/jobs), and
### three of the copies never reached their own `on-timeout` branch:
### a cancelled task ends with the `:error` signal and the value
### `errors/deadline-message`, and a copy that tested `:error` first
### re-raised that bare string instead. Written once, the outcome is
### classified once — with `errors/deadline?`, the whole value and
### never a substring.
###
### Two shapes. `run` never throws and answers with a tagged tuple —
### the primitive, for a loop that has to count what happened. `call`
### is the everyday one: the value, or what `on-timeout` says, or the
### work's own error re-raised untouched.
###
### Without a deadline (nil or non-positive seconds) neither spawns a
### task: the work runs inline on the caller. A client used inside a
### request should not pay for a supervisor it did not ask for, and an
### inline call is cancelled with its caller, which is the right thing.
### "Non-positive means none" is the one reading every caller gets:
### a `:void.http/timeout`, a client's `:timeout`, a jobs interval —
### the schemas that guard those keys refuse a zero at config time,
### and a caller that must treat a zero as "already expired" (grpc's
### `Connect-Timeout-Ms`) decides so before it gets here.
###
### With one, the child is cancelled if the caller leaves before the
### outcome arrives — a checkout abandoned because the request above
### it timed out must not leave a taker parked on the pool's channel
### to swallow a later handover. That cancellation is cooperative in
### the sense that it lands at the child's next ev operation, but it
### is not lossless: a value scheduled for the child by `ev/give` to
### its parked `ev/take` sits in the run queue, and a cancel queued
### ahead of it supersedes it — the child dies and the value is gone,
### neither delivered nor left in the channel. A payload that must
### not be lost therefore does not travel through the channel a child
### task is parked on; it is written somewhere the caller's own exit
### can read (the pool hands over through the waiter record and uses
### the channel as a wake-up only).

(import ./errors :as errors)

(defn- deadline?
  "A positive number of seconds, i.e. a deadline that is actually set."
  [seconds]
  (and (number? seconds) (pos? seconds)))

(defn- raise-timeout
  "The default `on-timeout`: the kernel's own kind, status 504."
  [seconds]
  (errors/raise :void/deadline
                (string/format "timed out after %.3g s" seconds)
                {:timeout seconds}))

(defn run
  ``Run `(f)` as its own supervised task, cancelled after `seconds`.
  Never throws; answers

      [:ok value]      f returned value
      [:timeout nil]   the deadline cancelled the task
      [:error err]     f raised err (the value, not a fiber)

  With no deadline (nil or non-positive) `f` runs inline and its
  error, if any, is still answered as `[:error err]`.``
  [seconds f]
  (if (not (deadline? seconds))
    (try [:ok (f)] ([e] [:error e]))
    (do
      (def sup (ev/chan 1))
      (def task (ev/go (fn deadline-task [] (f)) nil sup))
      (ev/deadline seconds task task)
      (def [sig fib]
        (defer (when (fiber/can-resume? task)
                 (protect (ev/cancel task "deadline: the caller left")))
          (ev/take sup)))
      (def value (fiber/last-value fib))
      (cond
        (= :ok sig) [:ok value]
        (errors/deadline? value) [:timeout nil]
        [:error value]))))

(defn call
  ``Run `(f)` under `seconds` and return its value. On a timeout
  return `(on-timeout)` — or, when there is none, raise
  `:void/deadline`. An error `f` raised is re-raised as it was, so a
  caller matches the work's own errors the way it always did.``
  [seconds f &opt on-timeout]
  (def [outcome value] (run seconds f))
  (case outcome
    :ok value
    :error (error value)
    (if on-timeout (on-timeout) (raise-timeout seconds))))
