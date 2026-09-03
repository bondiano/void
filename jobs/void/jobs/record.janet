### void/jobs/record — the queued job: its fields, its states and the
### transitions between them.
###
### A record is a plain table, and deliberately flat: every backend has
### to be able to store it, and the ones that are not Janet — a
### Postgres row, a redis hash — store scalars. The only two fields
### that are not scalars are :args and :result, and they travel as jdn
### (./record encodes; a backend that has columns may keep the rest in
### columns, which is what void/jobs-db does).
###
### The state machine is small enough to state in full:
###
###   :pending    queued; :run-at says from when it may be claimed
###   :running    claimed by a worker (:token, :claimed-at)
###   :waiting    a flow parent, held until :children-left reaches 0
###   :completed  the handler returned; :result is what it returned
###   :dead       out of attempts, or killed by hand — the dead letter
###               queue is this state, not a second store
###
### A retry is not a state: a failed job that has attempts left goes
### back to :pending with a later :run-at, keeping its :attempt count
### and the tail of its :failures. That is what makes "retry" and
### "delayed" the same mechanism, and it is why a worker that dies
### mid-job is recoverable — the claim expires and the record is still
### :running with a stale :token, which is exactly what `reap!` looks
### for.

(def states
  "Every state a record can be in, in lifecycle order."
  [:pending :running :waiting :completed :dead])

(def live-states
  "States that still owe work — what a unique key holds against, and
  what `counts` calls the backlog."
  [:pending :running :waiting])

(def fields
  ``Every field of a record, in a stable order — the order `void jobs
  show` prints and the column order void/jobs-db creates.``
  [:id :job :args :queue :priority :state
   :attempt :max-attempts :backoff :timeout
   :run-at :enqueued-at :started-at :finished-at
   :unique-key :unique-until :group :parent :children-left :children
   :result :error :failures :token])

(def max-failures
  ``How many failures a record carries with it. The last one is the
  one being debugged; the ones before it are the evidence that it is
  the same failure every time. Everything older is a log record's
  job, not a queue's.``
  5)

# -- ids -----------------------------------------------------------------

(defn- hex [bytes]
  (def b @"")
  (each byte bytes (buffer/push-string b (string/format "%02x" byte)))
  (string b))

(defn new-id
  ``A job id: the second it was created, then eight random bytes.
  Time first so that ids sort roughly in creation order — a backend
  breaking a priority tie by id then breaks it in favour of the job
  that has been waiting longer, which is the tie-break everyone
  expects.``
  [&opt now]
  (string/format "%011x%s" (math/floor (or now (os/time))) (hex (os/cryptorand 8))))

# -- construction --------------------------------------------------------

(defn make
  ``Build a pending record. Every policy field is expected to be
  resolved already — the definition's options merged over the [:jobs]
  defaults merged under the per-enqueue overrides — because a record
  is what several processes read, and a field left to be decided later
  is a field two processes decide differently.``
  [fields0]
  (def f (or fields0 {}))
  (def now (get f :now (os/clock :realtime)))
  (unless (keyword? (get f :job))
    (errorf "a job record needs a :job name, got %q" (get f :job)))
  (def args (get f :args []))
  (unless (indexed? args)
    (errorf "job %q: :args must be a tuple, got %q" (f :job) args))
  (def children (get f :children-left))
  @{:id (get f :id (new-id now))
    :job (f :job)
    :args (tuple ;args)
    :queue (get f :queue :default)
    :priority (get f :priority 5)
    :state (if (and children (pos? children)) :waiting :pending)
    :attempt 0
    :max-attempts (get f :max-attempts 3)
    :backoff (get f :backoff)
    :timeout (get f :timeout)
    :run-at (get f :run-at now)
    :enqueued-at now
    :started-at nil
    :finished-at nil
    :unique-key (get f :unique-key)
    :unique-until (get f :unique-until)
    :group (get f :group)
    :parent (get f :parent)
    :children-left children
    :children (when children @[])
    :result nil
    :error nil
    :failures @[]
    :token nil})

(defn copy
  "A shallow copy of a record — what a backend hands out so that a
  caller mutating what it got cannot mutate what is stored."
  [r]
  (when r
    (def out (table ;(kvs r)))
    (put out :failures (array ;(get r :failures [])))
    (when-let [cs (get r :children)]
      (put out :children (array ;cs)))
    out))

# -- predicates ----------------------------------------------------------

(defn live?
  "True while the record still owes work."
  [r]
  (truthy? (index-of (get r :state) live-states)))

(defn runnable?
  "True when a pending record may be claimed at `now`."
  [r now]
  (and (= :pending (get r :state))
       (<= (get r :run-at 0) now)))

(defn stalled?
  ``True when a claim has outlived `ttl` seconds — the worker holding
  it is gone (killed, crashed, or the machine went away) and the
  record has to go back into the queue. A running job whose handler is
  merely slow is not stalled: the worker refreshes :claimed-at while
  it runs.``
  [r now ttl]
  (and (= :running (get r :state))
       (number? (get r :claimed-at (get r :started-at)))
       (> (- now (get r :claimed-at (get r :started-at))) ttl)))

# -- transitions ---------------------------------------------------------
#
# All four return the record, mutated. A backend calls them on its own
# copy and then persists it; the runtime never persists behind a
# backend's back.

(defn start!
  "Mark a record claimed by `token` at `now`."
  [r token now]
  (put r :state :running)
  (put r :token token)
  (put r :attempt (inc (get r :attempt 0)))
  (put r :started-at now)
  (put r :claimed-at now)
  (put r :error nil)
  r)

(defn complete!
  "Mark a record finished, carrying what the handler returned."
  [r result now]
  (put r :state :completed)
  (put r :result result)
  (put r :error nil)
  (put r :token nil)
  (put r :finished-at now)
  r)

(defn- note-failure! [r err now]
  (def fs (get r :failures @[]))
  (array/push fs {:attempt (get r :attempt 0) :at now :error err})
  # a positive start: Janet counts -1 as one past the last index, so a
  # negative one here would quietly drop an extra record
  (put r :failures
       (array ;(if (> (length fs) max-failures)
                 (array/slice fs (- (length fs) max-failures))
                 fs)))
  (put r :error err)
  r)

(defn retry!
  "Send a failed record back to the queue, to be claimed again no
  earlier than `run-at`."
  [r err run-at now]
  (note-failure! r err now)
  (put r :state :pending)
  (put r :token nil)
  (put r :run-at run-at)
  (put r :started-at nil)
  (put r :claimed-at nil)
  r)

(defn defer!
  ``Put a claimed record back in the queue without counting the claim
  as an attempt — what a worker does when a rate limit turns out to
  have closed between the claim and the run. It is not a failure and
  it must not consume one of the job's lives.``
  [r run-at]
  (put r :state :pending)
  (put r :attempt (max 0 (dec (get r :attempt 0))))
  (put r :token nil)
  (put r :run-at run-at)
  (put r :started-at nil)
  (put r :claimed-at nil)
  r)

(defn kill!
  ``Move a record to the dead letter queue: out of attempts, or a
  failure the runtime will not retry. `err` may be nil when a human
  did it.``
  [r err now]
  (when err (note-failure! r err now))
  (put r :state :dead)
  (put r :token nil)
  (put r :finished-at now)
  r)

(defn revive!
  ``Put a dead record back at the front of the queue with its attempt
  count reset — what `void jobs retry` does. The failures stay: the
  history of why it died is the reason anyone is retrying it.``
  [r now]
  (put r :state :pending)
  (put r :attempt 0)
  (put r :token nil)
  (put r :error nil)
  (put r :run-at now)
  (put r :started-at nil)
  (put r :claimed-at nil)
  (put r :finished-at nil)
  r)

# -- serialization -------------------------------------------------------

(defn encode
  ``A record as one jdn string — what a backend without columns
  stores. Throws naming the job when an argument is not plain data,
  because "this cannot be queued" is a mistake to make at enqueue
  time, in the caller's stack, and not at claim time in a worker.``
  [r]
  (def [ok s]
    (protect (string/format "%j" (table/to-struct (table ;(kvs r))))))
  (unless ok
    (errorf "job %q cannot be serialized (%s) — arguments and results must be plain data: numbers, strings, keywords, tuples and tables of them"
            (get r :job) (if (string? s) s (describe s))))
  s)

(defn decode
  "A record back from `encode`."
  [s]
  (def r (parse s))
  (unless (dictionary? r)
    (errorf "a stored job should be a dictionary, got %q" r))
  (copy r))

(defn encode-value
  "One value (arguments, a result) as jdn — for a backend that keeps
  the scalars in columns and only these two out of them."
  [v &opt what]
  (def [ok s] (protect (string/format "%j" v)))
  (unless ok
    (errorf "%s cannot be serialized (%s) — job data must be plain data"
            (or what "the value") (if (string? s) s (describe s))))
  s)

(defn decode-value
  "The inverse of `encode-value`; nil for a nil column."
  [s]
  (when (and s (not= "" s)) (parse s)))

# -- rendering -----------------------------------------------------------

(defn ago
  ``How long ago `t` was, in one column's worth of characters: "now",
  "42s", "9m", "3h", "5d". The age of a record is read in a terminal
  and in a back office, and two spellings of "3h" would drift.``
  [t now]
  (if (nil? t)
    "-"
    (let [d (- now t)]
      (cond
        (< d 1) "now"
        (< d 60) (string/format "%ds" (math/round d))
        (< d 3600) (string/format "%dm" (math/round (/ d 60)))
        (< d 86400) (string/format "%dh" (math/round (/ d 3600)))
        (string/format "%dd" (math/round (/ d 86400)))))))

(defn summary
  "One line for `void jobs list`: id, state, queue, job, attempts, age."
  [r &opt now]
  (def t (or now (os/clock :realtime)))
  (string/format "%s  %-9s %-10s %-24s %d/%d  %s%s"
                 (get r :id) (get r :state) (get r :queue) (get r :job)
                 (get r :attempt 0) (get r :max-attempts 0)
                 (ago (or (get r :finished-at) (get r :started-at) (get r :enqueued-at)) t)
                 (if-let [e (get r :error)] (string "  " e) "")))
