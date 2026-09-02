### void/jobs-redis — the job queue in redis (SPEC.md §5.12, ADR-0012).
###
### The piece of void/jobs that needs void/redis, kept a separate
### plugin so an application whose jobs live in its heap — or in its
### database — never loads a redis client. Add it to the composition
### and say which backend you mean:
###
###     (void/run! {:plugins [:void/redis :void/jobs :void/jobs-redis ...]})
###     # config/prod.janet
###     {:void/jobs-backend {:impl :jobs/redis}}
###
### It is the backend to reach for when the throughput matters more
### than the paper trail: a claim is one round trip and no transaction,
### tens of thousands of jobs a second are unremarkable, and nothing
### about it touches the database the jobs are working on. What it is
### not is durable in the way a table is — redis persistence is
### redis's, and a queue that must not lose a job when a machine loses
### power belongs in void/jobs-db.
###
### The shape is BullMQ's, because BullMQ's is right:
###
###   <p>j:<id>              a hash — one field per record field, so
###                          `HGETALL` in redis-cli is a job you can
###                          read at three in the morning
###   <p>q:<queue>:delayed   a zset of ids scored by :run-at — the jobs
###                          that are not runnable yet
###   <p>q:<queue>:ready     a zset of ids scored by :priority — the
###                          jobs that are, in the order they run
###   <p>running             a zset of ids scored by the claim time,
###                          which is what makes reaping one range query
###   <p>s:<queue>:<state>   a set per state — what `counts` counts
###                          without reading a single record
###   <p>u:<key>             a unique key, held with SET NX
###
### Claiming is a Lua script, because it has to be four things at once:
### promote whatever became runnable, skip the groups already at their
### cap, take the best remaining id, and mark it claimed — with nothing
### interleaved between them. Redis runs a script with the server to
### itself, so what would be a transaction elsewhere is a script here,
### and the claim stays one round trip.
###
### Two honest caveats. **Retention is trimmed, not transactional**: a
### finished job is pushed onto a capped list and what falls off the
### end is deleted right after, so a crash between the two leaves a
### record that nothing points at until the next settle in that queue
### trims again. **`list` reads records**, because a set of ids is not
### an index of anything else; it is an inspection path, and it is
### bounded by its :limit rather than by the size of the queue.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/redis/commands :as rcmd)
(import void/redis/state :as redis)
(import ./backend :as backend)
(import ./record :as record)

(def log-ns "void.jobs.redis")

(def Config
  "Schema of the [:jobs-redis] config slice."
  {:prefix [:optional :string]
   :keep-completed [:optional [:int {:min 0}]]
   :keep-dead [:optional [:int {:min 0}]]
   # how many due records one claim may promote, and how far down the
   # ready set it may look for a group that is not capped
   :promote-batch [:optional [:int {:min 1}]]
   :scan-depth [:optional [:int {:min 1}]]})

(def defaults
  ``Defaults of the [:jobs-redis] slice. The prefix is this plugin's
  own, on top of whatever `[:redis :prefix]` already puts in front of
  every key — one names the application, the other names the queue,
  and a database shared by both is still readable.``
  {:prefix "jobs:"
   :keep-completed 1000
   :keep-dead 10_000
   :promote-batch 200
   :scan-depth 64})

# -- records as hashes ---------------------------------------------------

(def hash-fields
  ``The hash field of every record field. Spelled like void/jobs-db's
  columns on purpose: one queue, two stores, one vocabulary.``
  [[:id "id" :string]
   [:job "job" :keyword]
   [:args "args" :jdn]
   [:queue "queue" :keyword]
   [:priority "priority" :number]
   [:state "state" :keyword]
   [:attempt "attempt" :number]
   [:max-attempts "max_attempts" :number]
   [:backoff "backoff" :jdn]
   [:timeout "timeout" :number]
   [:run-at "run_at" :number]
   [:enqueued-at "enqueued_at" :number]
   [:started-at "started_at" :number]
   [:claimed-at "claimed_at" :number]
   [:finished-at "finished_at" :number]
   [:unique-key "unique_key" :string]
   [:unique-until "unique_until" :number]
   [:group "group_key" :string]
   [:parent "parent" :string]
   [:children-left "children_left" :number]
   [:children "children" :jdn]
   [:result "result" :jdn]
   [:error "error" :string]
   [:failures "failures" :jdn]
   [:token "token" :string]])

(defn record->hash
  "A record as HSET arguments: field, value, field, value. Absent
  fields are absent rather than empty, so `HGETALL` shows what a job
  has and not what it might have had."
  [r]
  (def out @[])
  (each [k field kind] hash-fields
    (def v (get r k))
    (unless (nil? v)
      (array/push out field)
      (array/push out
                  (case kind
                    :jdn (record/encode-value v (string "the " field))
                    :number (string v)
                    (string v)))))
  out)

(defn hash->record
  "A `HGETALL` reply back into a record. Redis answers in strings; the
  field table says which of them were numbers, keywords and jdn."
  [h]
  (when (and h (not (empty? h)))
    (def out @{})
    (each [k field kind] hash-fields
      (def v (get h field))
      (unless (nil? v)
        (put out k
             (case kind
               :jdn (record/decode-value v)
               :number (scan-number v)
               :keyword (keyword v)
               (string v)))))
    (put out :args (tuple ;(or (get out :args) [])))
    (put out :failures (array ;(or (get out :failures) [])))
    (when (get out :children)
      (put out :children (array ;(get out :children))))
    out))

# -- the scripts ---------------------------------------------------------
#
# Everything that has to be indivisible is here rather than in a
# MULTI: a script sees the server to itself, and a claim that promoted
# a job and then lost it to another worker between two commands would
# be a queue that runs a job twice.

(def claim-script
  ``Promote what has become runnable, then take the first ready job
  whose group is not capped, mark it claimed and answer with it.``
  (rcmd/script
    ``
    local jobs = ARGV[1]
    local now = tonumber(ARGV[2])
    local token = ARGV[3]
    local nskip = tonumber(ARGV[4])
    local promote = tonumber(ARGV[5])
    local depth = tonumber(ARGV[6])
    local skip = {}
    for i = 1, nskip do skip[ARGV[6 + i]] = true end

    local due = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', now, 'LIMIT', 0, promote)
    for _, id in ipairs(due) do
      redis.call('ZREM', KEYS[1], id)
      local pr = redis.call('HGET', jobs .. id, 'priority')
      if pr then redis.call('ZADD', KEYS[2], tonumber(pr), id) end
    end

    local cands = redis.call('ZRANGE', KEYS[2], 0, depth - 1)
    for _, id in ipairs(cands) do
      local key = jobs .. id
      if redis.call('EXISTS', key) == 0 then
        redis.call('ZREM', KEYS[2], id)
      else
        local g = redis.call('HGET', key, 'group_key')
        if not (g and skip[g]) then
          redis.call('ZREM', KEYS[2], id)
          local attempt = tonumber(redis.call('HGET', key, 'attempt') or '0') + 1
          redis.call('HSET', key, 'state', 'running', 'token', token,
                     'attempt', attempt, 'started_at', ARGV[2], 'claimed_at', ARGV[2])
          redis.call('SREM', KEYS[3], id)
          redis.call('SADD', KEYS[4], id)
          redis.call('ZADD', KEYS[5], now, id)
          return redis.call('HGETALL', key)
        end
      end
    end
    return nil
    ``))

(def reap-script
  ``Take over the claims that have gone stale — re-token them in place
  so that a second reaper arriving at the same moment finds nothing.``
  (rcmd/script
    ``
    local jobs = ARGV[1]
    local cutoff = tonumber(ARGV[2])
    local now = ARGV[3]
    local token = ARGV[4]
    local limit = tonumber(ARGV[5])
    local ids = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', cutoff, 'LIMIT', 0, limit)
    local out = {}
    for _, id in ipairs(ids) do
      local key = jobs .. id
      if redis.call('EXISTS', key) == 0 then
        redis.call('ZREM', KEYS[1], id)
      else
        redis.call('HSET', key, 'token', token, 'claimed_at', now)
        redis.call('ZADD', KEYS[1], now, id)
        out[#out + 1] = redis.call('HGETALL', key)
      end
    end
    return out
    ``))

(def settle-script
  ``Rewrite a record, but only while the token that claimed it still
  owns it. A claim the reaper re-tokened away must not be overwritten
  by its old holder: the job ran again under the new token, and that
  run's settle is the one that counts.``
  (rcmd/script
    ``
    local key = KEYS[1]
    local cur = redis.call('HGET', key, 'token')
    if cur and cur ~= ARGV[1] then return 0 end
    redis.call('DEL', key)
    redis.call('HSET', key, unpack(ARGV, 2))
    return 1
    ``))

(def touch-script
  ``Refresh the claims this token still holds — and only those: a
  heartbeat must not keep alive a claim the reaper already gave to
  another worker.``
  (rcmd/script
    ``
    local jobs = ARGV[1]
    local now = ARGV[2]
    local token = ARGV[3]
    local n = 0
    for i = 4, #ARGV do
      local id = ARGV[i]
      if redis.call('HGET', jobs .. id, 'token') == token then
        redis.call('HSET', jobs .. id, 'claimed_at', now)
        redis.call('ZADD', KEYS[1], tonumber(now), id)
        n = n + 1
      end
    end
    return n
    ``))

(def lock-script
  ``Take a lease, or renew the one we already hold. `SET NX` alone
  cannot renew, and a lock that cannot be renewed by its owner is one
  that expires under a schedule still running.``
  (rcmd/script
    ``
    local cur = redis.call('GET', KEYS[1])
    if cur == false or cur == ARGV[1] then
      redis.call('SET', KEYS[1], ARGV[1], 'PX', tonumber(ARGV[2]))
      return 1
    end
    return 0
    ``))

(def unlock-script
  "Release a lease, but only the one we took."
  (rcmd/script
    ``
    if redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[1])
    end
    return 0
    ``))

(def rate-script
  ``A fixed-window counter. The expiry is set when the window is
  created rather than on every call: a window that slid with each
  increment would never close.``
  (rcmd/script
    ``
    local limit = tonumber(ARGV[1])
    local ms = tonumber(ARGV[2])
    local n = redis.call('INCR', KEYS[1])
    if n == 1 then redis.call('PEXPIRE', KEYS[1], ms) end
    if n <= limit then return 0 end
    local left = redis.call('PTTL', KEYS[1])
    if left < 0 then left = ms end
    return left
    ``))

(def release-parent-script
  ``Record a finished child on its parent and, if it was the last one,
  move the parent into the queue. Two children finishing in the same
  instant must not both decide they were last, which is the whole
  reason this is a script.``
  (rcmd/script
    ``
    local key = KEYS[1]
    if redis.call('EXISTS', key) == 0 then return nil end
    local left = tonumber(redis.call('HGET', key, 'children_left') or '0') - 1
    if left < 0 then left = 0 end
    redis.call('HSET', key, 'children_left', tostring(left),
               'children', ARGV[1])
    local state = redis.call('HGET', key, 'state')
    if left == 0 and state == 'waiting' then
      redis.call('HSET', key, 'state', 'pending', 'run_at', ARGV[2])
      redis.call('SREM', KEYS[2], ARGV[3])
      redis.call('SADD', KEYS[3], ARGV[3])
      redis.call('ZADD', KEYS[4], tonumber(ARGV[4]), ARGV[3])
      return redis.call('HGETALL', key)
    end
    return nil
    ``))

# -- the backend ---------------------------------------------------------

(defn- fields->table
  ``A HGETALL reply as a table of strings. It arrives in two shapes
  and both are correct: a RESP3 map from the command itself, and a
  flat [field value field value] array from a script (Lua has no map
  type to answer with). Values are stringified because the codec is
  the client's business and these fields are this plugin's.``
  [reply]
  (cond
    (nil? reply) nil
    (and (dictionary? reply) (not (empty? reply)))
    (tabseq [k :keys reply] (string k) (string (get reply k)))

    (and (indexed? reply) (not (empty? reply)))
    (do
      (def out @{})
      (var i 0)
      (while (< i (dec (length reply)))
        (put out (string (get reply i)) (string (get reply (inc i))))
        (+= i 2))
      out)

    nil))

(defn store
  ``A `:void/jobs-backend` over the running redis client. Nothing is
  captured but the key prefix and the retention caps: which server,
  which database and which client prefix are read off the client at
  call time, so the backend outlives a restart of the client under
  it.``
  [opts]
  (def p (get opts :prefix (defaults :prefix)))
  (def keep-completed (get opts :keep-completed (defaults :keep-completed)))
  (def keep-dead (get opts :keep-dead (defaults :keep-dead)))
  (def promote-batch (get opts :promote-batch (defaults :promote-batch)))
  (def scan-depth (get opts :scan-depth (defaults :scan-depth)))

  (defn jkey [id] (string p "j:" id))
  (defn jobs-prefix [] (redis/prefixed (string p "j:")))
  (defn ready [q] (string p "q:" q ":ready"))
  (defn delayed [q] (string p "q:" q ":delayed"))
  (defn state-set [q st] (string p "s:" q ":" st))
  (defn running-z [] (string p "running"))
  (defn queues-set [] (string p "queues"))
  (defn unique-key [k] (string p "u:" k))
  (defn done-list [st] (string p "done:" st))

  (defn read-record [id]
    (hash->record (fields->table (redis/call ["HGETALL" (redis/prefixed (jkey id))]))))

  (defn known-queues []
    (map keyword (redis/call ["SMEMBERS" (redis/prefixed (queues-set))])))

  (defn index-commands
    ``The commands that put a record in the right indexes for the
    state it is now in. Every state set of the queue is cleared first:
    it is five cheap SREMs against having to know which state the
    record was in a moment ago, which is knowledge the backend does
    not have and should not need.``
    [r]
    (def id (r :id))
    (def q (r :queue))
    (def out @[])
    (each st record/states
      (array/push out ["SREM" (redis/prefixed (state-set q st)) id]))
    (array/push out ["SADD" (redis/prefixed (state-set q (r :state))) id])
    (array/push out ["ZREM" (redis/prefixed (ready q)) id])
    (array/push out ["ZREM" (redis/prefixed (delayed q)) id])
    (array/push out ["ZREM" (redis/prefixed (running-z)) id])
    (case (r :state)
      :pending
      (array/push out
                  (if (> (get r :run-at 0) (os/clock :realtime))
                    ["ZADD" (redis/prefixed (delayed q)) (get r :run-at 0) id]
                    ["ZADD" (redis/prefixed (ready q)) (get r :priority 5) id]))
      :running
      (array/push out ["ZADD" (redis/prefixed (running-z))
                       (get r :claimed-at (os/clock :realtime)) id])
      nil)
    out)

  (defn trim-finished!
    ``Keep the finished records of one state down to its cap. Best
    effort and deliberately after the fact: what falls off the list is
    deleted next, and a crash in between leaves a record nothing points
    at rather than a list that lies about what exists.``
    [st]
    (def cap (if (= :completed st) keep-completed keep-dead))
    (when (pos? cap)
      (def key (redis/prefixed (done-list st)))
      (def extra (redis/call ["LRANGE" key cap -1]))
      (unless (empty? extra)
        (redis/call ["LTRIM" key 0 (dec cap)])
        (def cmds @[])
        (each e extra
          (def [q id] (string/split ":" (string e) 0 2))
          (array/push cmds ["DEL" (redis/prefixed (jkey id))])
          (array/push cmds ["SREM" (redis/prefixed (state-set q st)) id]))
        (redis/pipeline cmds))))

  {:name :redis
   :shared? true

   :push!
   (fn redis-push [r]
     (def now (get r :enqueued-at (os/clock :realtime)))
     (def k (get r :unique-key))
     (def held
       (when k
         (def ttl (get r :unique-until))
         (def args (if ttl
                     ["SET" (redis/prefixed (unique-key k)) (r :id) "NX"
                      "PX" (max 1 (math/round (* 1000 (- ttl now))))]
                     ["SET" (redis/prefixed (unique-key k)) (r :id) "NX"]))
         (nil? (redis/call args))))
     (if held
       nil
       (do
         (redis/pipeline
           (array ["HSET" (redis/prefixed (jkey (r :id))) ;(record->hash r)]
                  ["SADD" (redis/prefixed (queues-set)) (string (r :queue))]
                  ;(index-commands r)))
         (record/copy r))))

   :claim!
   (fn redis-claim [o]
     (def now (get o :now (os/clock :realtime)))
     (def token (get o :token))
     (def skip (sorted (keys (get o :skip-groups {}))))
     (var out nil)
     (each q (get o :queues [])
       (when (nil? out)
         (def reply
           (claim-script
             [(delayed q) (ready q) (state-set q :pending) (state-set q :running)
              (running-z)]
             [(jobs-prefix) (string now) (string token) (string (length skip))
              (string promote-batch) (string scan-depth) ;skip]))
         (when (and reply (not (empty? reply)))
           (set out (hash->record (fields->table reply))))))
     out)

   :settle!
   (fn redis-settle [r &opt expected]
     (def now (get r :finished-at (os/clock :realtime)))
     (def finished (truthy? (index-of (r :state) [:completed :dead])))
     (def release-unique
       (and finished
            (get r :unique-key)
            (or (nil? (get r :unique-until)) (<= (get r :unique-until) now))))
     # with a token to fence on, the record itself is rewritten by the
     # script — atomically, and only while the token still owns the
     # claim. 0 says a reaper gave the job away: nothing is written,
     # nil is the answer
     (def written
       (if expected
         (= 1 (settle-script [(jkey (r :id))]
                             [(string expected) ;(record->hash r)]))
         (do
           (redis/pipeline
             (array ["DEL" (redis/prefixed (jkey (r :id)))]
                    ["HSET" (redis/prefixed (jkey (r :id))) ;(record->hash r)]))
           true)))
     (if (not written)
       nil
       (do
         (def cmds (array ;(index-commands r)))
         (when release-unique
           (array/push cmds ["DEL" (redis/prefixed (unique-key (r :unique-key)))]))
         (when finished
           (array/push cmds ["LPUSH" (redis/prefixed (done-list (r :state)))
                             (string (r :queue) ":" (r :id))]))
         (redis/pipeline cmds)
         (when finished (trim-finished! (r :state)))
         (record/copy r))))

   :fetch (fn redis-fetch [id] (read-record id))

   :list
   (fn redis-list [o0]
     (def o (or o0 {}))
     (def limit (math/floor (get o :limit 50)))
     (def qs (if-let [q (get o :queue)] [q] (known-queues)))
     (def sts (if-let [s (get o :state)] [s] record/states))
     (def ids @[])
     (each q qs
       (each st sts
         (each id (redis/call ["SMEMBERS" (redis/prefixed (state-set q st))])
           (array/push ids (string id)))))
     (def out @[])
     (each id (sorted ids)
       (when (< (length out) limit)
         (when-let [r (read-record id)]
           (when (and (or (nil? (o :job)) (= (o :job) (r :job)))
                      (or (nil? (o :parent)) (= (o :parent) (r :parent))))
             (array/push out r)))))
     (tuple ;out))

   :counts
   (fn redis-counts [&opt _]
     (def out @{})
     (each q (known-queues)
       (def t @{})
       (each st record/states
         (def n (redis/call ["SCARD" (redis/prefixed (state-set q st))]))
         (when (pos? n) (put t st n)))
       (unless (empty? t) (put out q (table/to-struct t))))
     (table/to-struct out))

   :remove!
   (fn redis-remove [id]
     (if-let [r (read-record id)]
       (do
         (def cmds (array ["DEL" (redis/prefixed (jkey id))]))
         (each st record/states
           (array/push cmds ["SREM" (redis/prefixed (state-set (r :queue) st)) id]))
         (array/push cmds ["ZREM" (redis/prefixed (ready (r :queue))) id])
         (array/push cmds ["ZREM" (redis/prefixed (delayed (r :queue))) id])
         (array/push cmds ["ZREM" (redis/prefixed (running-z)) id])
         (when-let [k (get r :unique-key)]
           (array/push cmds ["DEL" (redis/prefixed (unique-key k))]))
         (redis/pipeline cmds)
         true)
       false))

   :clear!
   (fn redis-clear [o0]
     (def o (or o0 {}))
     (def qs (if-let [q (get o :queue)] [q] (known-queues)))
     (def sts (if-let [s (get o :state)] [s] record/states))
     (var n 0)
     (each q qs
       (each st sts
         (each id (redis/call ["SMEMBERS" (redis/prefixed (state-set q st))])
           (def r (read-record (string id)))
           (def cmds (array ["DEL" (redis/prefixed (jkey id))]
                            ["SREM" (redis/prefixed (state-set q st)) id]
                            ["ZREM" (redis/prefixed (ready q)) id]
                            ["ZREM" (redis/prefixed (delayed q)) id]
                            ["ZREM" (redis/prefixed (running-z)) id]))
           (when-let [k (get r :unique-key)]
             (array/push cmds ["DEL" (redis/prefixed (unique-key k))]))
           (redis/pipeline cmds)
           (++ n))))
     n)

   :reap!
   (fn redis-reap [o]
     (def now (get o :now (os/clock :realtime)))
     (def cutoff (- now (get o :ttl 60)))
     (def reply (reap-script [(running-z)]
                             [(jobs-prefix) (string cutoff) (string now)
                              (string (get o :token)) (string (get o :limit 100))]))
     (tuple ;(filter |(not (nil? $))
                     (map |(hash->record (fields->table $)) (or reply [])))))

   :touch!
   (fn redis-touch [ids nowt &opt token]
     (cond
       (empty? ids) 0

       token
       (touch-script [(running-z)]
                     [(jobs-prefix) (string nowt) (string token)
                      ;(map string ids)])

       (do
         (redis/pipeline
           (array ;(mapcat
                     (fn [id]
                       [["HSET" (redis/prefixed (jkey id)) "claimed_at" (string nowt)]
                        ["ZADD" (redis/prefixed (running-z)) nowt id]])
                     ids)))
         (length ids))))

   :release-parent!
   (fn redis-release-parent [child]
     (when-let [pid (get child :parent)]
       (when-let [parent (read-record pid)]
         (def children
           (array ;(or (get parent :children) [])
                  {:id (child :id) :job (child :job) :result (get child :result)}))
         (def now (os/clock :realtime))
         (def reply
           (release-parent-script
             [(jkey pid)
              (state-set (parent :queue) :waiting)
              (state-set (parent :queue) :pending)
              (ready (parent :queue))]
             [(record/encode-value children "the children")
              (string now) pid (string (get parent :priority 5))]))
         (when (and reply (not (empty? reply)))
           (hash->record (fields->table reply))))))

   :lock!
   (fn redis-lock [name ttl token _now]
     (= 1 (lock-script [(string p "lock:" name)]
                       [(string token) (string (max 1 (math/round (* 1000 ttl))))])))

   :unlock!
   (fn redis-unlock [name token]
     (pos? (unlock-script [(string p "lock:" name)] [(string token)])))

   :rate-take!
   (fn redis-rate-take [queue limit duration now]
     (if (or (nil? limit) (nil? duration) (<= limit 0) (<= duration 0))
       0
       (do
         (def window (math/floor (/ now duration)))
         (def ms (max 1 (math/round (* 1000 duration))))
         (def left (rate-script [(string p "rate:" queue ":" window)]
                                [(string limit) (string ms)]))
         (if (pos? left) (/ left 1000) 0))))

   :stats
   (fn redis-stats []
     {:store :redis
      :prefix p
      :keep-completed keep-completed
      :keep-dead keep-dead})

   # the pool belongs to the redis client component, which closes it
   :close (fn redis-close [] nil)})

# -- the component -------------------------------------------------------

(def component
  (system/component :jobs/redis
    :doc "The job queue in redis: a hash per record, a zset per queue
    for what is ready and another for what is delayed, a set per state
    for the counts, and a Lua script for the one step that has to be
    indivisible — promote, skip the capped groups, take the best id,
    mark it claimed."
    :deps [:redis/client]
    :provides [:void/jobs-backend]
    :config {:key :jobs-redis :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (merge defaults (or cfg0 {})))
      (def client (deps :redis/client))
      (log/info "jobs redis backend ready" :ns log-ns
                :prefix (cfg :prefix)
                :redis-prefix (get client :prefix "")
                :keep-completed (cfg :keep-completed)
                :keep-dead (cfg :keep-dead))
      (store cfg))
    :stop
    (fn stop [b] ((b :close)))
    :health
    (fn health [b] (merge {:status :up} ((b :stats))))))

(plugin/defplugin void/jobs-redis
  :doc "The job queue in redis: a :void/jobs-backend over void/redis — a hash per job, zsets for what is ready and what is delayed, a Lua claim that promotes, skips capped groups and marks the job running in one round trip, plus shared locks and rate-limit windows for a fleet of workers."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/jobs ">=0.0.1" :void/redis ">=0.0.1"}
  :config-key :jobs-redis
  :config-schema Config
  :config-defaults defaults
  :components [component])
