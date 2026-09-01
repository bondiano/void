### void/bus/memory — the in-process backend (SPEC.md §5.22).
###
### A channel per consumer group and a fiber draining it. That is the
### whole implementation, and it is the same answer
### `void/core/hooks`'s event bus gives, one layer down: `publish!`
### never runs a handler inline, so a subscriber that is slow slows
### the publisher only once its buffer is full, and a subscriber that
### throws never reaches the fiber that published.
###
### **What it promises, and what it does not.** At-most-once, ordered
### per group, not durable, not shared. A message published while
### nobody is consuming is *gone* — there is no log here to catch up
### with, and pretending otherwise (a ring buffer replayed to a late
### subscriber) would make the in-process backend behave unlike every
### backend it is meant to be a stand-in for. A process that dies with
### messages in a buffer takes them with it. Both facts are declared
### rather than discovered: `void bus stats` prints them, the broker
### logs them at boot, and `publish-tx!` refuses this backend outright.
###
### That leaves it exactly what it is for: a monolith whose consumers
### are in the same process as its publishers, and every test in every
### package that has to watch a message arrive without standing up a
### database. Both are real, and both are why the default backend is
### this one.
###
### The history ring is the one thing here that is not delivery: the
### last `[:bus :memory :keep]` envelopes, so that `void bus tail` and
### a test's `bus/recent` can show what went past. It is an inspection
### buffer and never a source of delivery — nothing is ever replayed
### out of it.

(import void/core/log :as log)

(def log-ns "void.bus.memory")

(def defaults
  "Defaults of the [:bus :memory] slice."
  {:buffer 64
   :keep 100})

(defn make
  "The mutable state behind an in-process backend."
  [&opt cfg]
  (default cfg {})
  @{:buffer (get cfg :buffer (defaults :buffer))
    :keep (get cfg :keep (defaults :keep))
    # group name -> subscription
    :groups @{}
    :history @[]
    :stats @{:published 0 :delivered 0 :dropped 0 :failed 0}})

(defn- bump! [m key]
  (put-in m [:stats key] (inc (get-in m [:stats key] 0))))

(defn- remember! [m env]
  (def h (m :history))
  (array/push h env)
  (when (> (length h) (m :keep))
    (array/remove h 0 (- (length h) (m :keep))))
  nil)

(defn recent
  "The last messages this backend saw, oldest first — an inspection
  buffer, never a replay log."
  [m &opt n]
  (def h (m :history))
  (def from (if n (max 0 (- (length h) n)) 0))
  (tuple ;(array/slice h from)))

(defn- wanted? [sub env]
  # the topics a group asked for are a hint the router re-checks; a
  # channel is a fixed allocation, so filtering here is what keeps a
  # group that wants one topic from spending its buffer on the other
  # nine
  (def match? (sub :match?))
  (or (nil? match?) (match? (env :topic))))

(defn store
  ``The backend value over the state `m` — the dictionary
  ./backend normalizes.``
  [m]
  {:name :memory
   :encoded? false
   :guarantees {:delivery :at-most-once
                :ordering :per-group
                :durable false
                :shared false}

   :publish!
   (fn publish [env]
     (bump! m :published)
     (remember! m env)
     (var n 0)
     (each name (sorted (keys (m :groups)))
       (def sub (get-in m [:groups name]))
       (when (and sub (not (sub :stopped)) (wanted? sub env))
         # blocks when the group's buffer is full: backpressure, which
         # is the only honest thing an in-heap queue can do about a
         # consumer that cannot keep up
         (ev/give (sub :chan) env)
         (++ n)))
     (when (zero? n) (bump! m :dropped))
     n)

   :consume!
   (fn consume [opts deliver]
     (def group (get opts :group :default))
     (when-let [prev (get-in m [:groups group])]
       (errorf "bus memory backend: consumer group %q is already consuming in this process" group))
     (def chan (ev/chan (get opts :buffer (m :buffer))))
     (def done (ev/chan 1))
     (def sub @{:group group :chan chan :done done :stopped false
                :match? (get opts :match?)})
     (put-in m [:groups group] sub)
     (ev/go
       (fn bus-memory-consumer []
         (var running true)
         (while running
           (def env (ev/take chan))
           (if (nil? env)
             (set running false)
             (do
               (def [ok err] (protect (deliver env)))
               (if ok
                 (bump! m :delivered)
                 (do
                   (bump! m :failed)
                   # at-most-once: nobody will hand this message over
                   # again, and saying so at :warn is the difference
                   # between a lost message and a silently lost message
                   (log/warn "message dropped by the in-process bus backend"
                             :ns log-ns :group group
                             :topic (get env :topic) :id (get env :id)
                             :err (if (string? err) err (describe err))))))))
         (ev/give done true)))
     sub)

   :stop!
   (fn stop [sub]
     (unless (sub :stopped)
       (put sub :stopped true)
       (put-in m [:groups (sub :group)] nil)
       (ev/chan-close (sub :chan))
       (def [ok _] (protect (ev/with-deadline 5 (ev/take (sub :done)))))
       (unless ok
         (log/warn "bus consumer did not stop within 5 s"
                   :ns log-ns :group (sub :group))))
     nil)

   :close
   (fn close []
     (each name (keys (m :groups))
       (when-let [sub (get-in m [:groups name])]
         (put sub :stopped true)
         (put-in m [:groups name] nil)
         (ev/chan-close (sub :chan))
         (protect (ev/with-deadline 5 (ev/take (sub :done))))))
     (array/clear (m :history))
     nil)

   :stats
   (fn stats []
     (merge (table/to-struct (m :stats))
            {:groups (sorted (keys (m :groups)))
             :buffered (sum (seq [name :in (keys (m :groups))]
                              (ev/count (get-in m [:groups name :chan]))))
             :history (length (m :history))}))})

(defn factory
  "The `:void.bus/backend` contribution void/bus ships."
  [state-out]
  {:name :memory
   :doc "In-process delivery: a channel per consumer group, at-most-once, ordered, gone when the process is. The default, and what a test consumes from."
   :make (fn make-memory [cfg]
           (def m (make (get cfg :memory {})))
           (when state-out (state-out m))
           (store m))})
