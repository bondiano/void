### void/redis/commands — the command surface (SPEC.md §5.10).
###
### Redis has some two hundred and forty commands. What is here is the
### handful an application reaches for daily, given a shape Janet code
### wants to read — a hash comes back a table, a missing key comes back
### nil, TTL says `:none` instead of -1 — plus the two things a wrapper
### must not leave to the caller: the key prefix and the codec.
###
### Everything else is one call away and needs no wrapper:
###
###     (redis/command "XADD" "events" "*" "kind" "signup")
###     (redis/call ["BLPOP" "q" 0] {:timeout :none})
###
### That is the deliberate line. `command` and `call` are the raw
### surface: they send exactly what they are given, which means they do
### **not** prefix keys and do **not** run values through the codec —
### use `(redis/key "...")` where a prefix is wanted. Every named
### helper below does both. A wrapper that guessed which arguments of
### an arbitrary command are keys would be wrong on the first
### interesting command (EVAL, ZADD, GEORADIUS, XREAD), and a wrapper
### that quietly prefixed some calls and not others is worse than one
### that says which is which.
###
### Values pass through the client's codec ([:redis :codec], default
### `:raw`); keys, hash fields and set members do not — those are
### identifiers, and an application that names a field `:count` wants
### the field called "count" on the server, not `":count"`.

(import ./codec :as codec)
(import ./conn :as conn)
(import ./resp :as resp)
(import ./state :as state)

# -- raw ------------------------------------------------------------------

(defn command
  ``Run one command exactly as written, and return its reply.

      (redis/command "XLEN" (redis/key "events"))

  No prefixing, no codec: this is the layer the named helpers are
  built on, and the one to reach for when the helper does not
  exist.``
  [& args]
  (state/call args))

(def call
  "See state/call — one command as an array, with :raw / :timeout
  options."
  state/call)

(def pipeline
  "See state/pipeline — several commands in one round trip."
  state/pipeline)

(def redis-key
  "A key as it reaches the server: the client's prefix plus `k`."
  state/prefixed)

# -- keys ------------------------------------------------------------------

(defn get-key
  "The value of `k`, decoded, or nil when the key does not exist."
  [k]
  (state/codec-decode (state/call ["GET" (state/prefixed k)])))

(defn set-key
  ``Set `k`. Options:

    :ex n / :px n   expire in n seconds / milliseconds
    :keep-ttl       keep the expiry the key already had
    :nx / :xx       only if the key is absent / present
    :get           return the previous value instead of a boolean

  Returns true, or false when :nx/:xx refused the write — which is
  what makes `(redis/set k v {:nx true :ex 30})` a lock.``
  [k v &opt opts]
  (default opts {})
  (def args @["SET" (state/prefixed k) (state/codec-encode v)])
  (when-let [ex (opts :ex)] (array/push args "EX") (array/push args ex))
  (when-let [px (opts :px)] (array/push args "PX") (array/push args px))
  (when (opts :keep-ttl) (array/push args "KEEPTTL"))
  (when (opts :nx) (array/push args "NX"))
  (when (opts :xx) (array/push args "XX"))
  (when (opts :get) (array/push args "GET"))
  (def r (state/call args))
  (if (opts :get)
    (state/codec-decode r)
    (not (nil? r))))

(defn del-keys
  "Delete keys; returns how many existed."
  [& ks]
  (if (empty? ks) 0 (state/call ["DEL" ;(map state/prefixed ks)])))

(defn exists?
  "Does the key exist?"
  [k]
  (pos? (state/call ["EXISTS" (state/prefixed k)])))

(defn expire
  "Give `k` a time to live, in seconds. False when there is no such
  key."
  [k seconds]
  (pos? (state/call ["EXPIRE" (state/prefixed k) seconds])))

(defn persist
  "Remove the expiry from `k` — it lives until deleted."
  [k]
  (pos? (state/call ["PERSIST" (state/prefixed k)])))

(defn key-ttl
  ``Seconds until `k` expires, `:none` when it has no expiry, nil when
  there is no such key. Redis says -1 and -2 for the last two, which
  are only distinguishable if you remember which is which.``
  [k]
  (def r (state/call ["TTL" (state/prefixed k)]))
  (cond
    (= -2 r) nil
    (= -1 r) :none
    r))

(defn key-type
  "The type of `k` as a keyword (:string :list :set :zset :hash
  :stream), or nil when there is no such key."
  [k]
  (def r (state/call ["TYPE" (state/prefixed k)]))
  (when (and r (not= "none" r)) (keyword r)))

(defn rename
  "Rename a key, keeping its time to live."
  [from to]
  (state/call ["RENAME" (state/prefixed from) (state/prefixed to)])
  nil)

# -- numbers ---------------------------------------------------------------

(defn incr
  "Add `by` (default 1) to the integer at `k`, and return the result.
  The counter starts at zero, so no key needs creating first."
  [k &opt by]
  (default by 1)
  (state/call ["INCRBY" (state/prefixed k) by]))

(defn decr
  "Subtract `by` (default 1) from the integer at `k`."
  [k &opt by]
  (default by 1)
  (state/call ["DECRBY" (state/prefixed k) by]))

(defn incr-float
  "Add a floating-point `by` to the number at `k`. Redis answers with a
  string (it keeps the decimal representation exact), and this returns
  the number it spells."
  [k by]
  (scan-number (state/call ["INCRBYFLOAT" (state/prefixed k) by])))

# -- several keys at once --------------------------------------------------

(defn mget
  "The values of several keys, decoded, in the order asked — a missing
  key is nil in its place."
  [& ks]
  (if (empty? ks)
    @[]
    (codec/decode-all (state/active-codec)
                      (state/call ["MGET" ;(map state/prefixed ks)]))))

(defn mset
  "Set several keys from a dictionary, in one command."
  [kvs]
  (def args @["MSET"])
  (eachp [k v] kvs
    (array/push args (state/prefixed k))
    (array/push args (state/codec-encode v)))
  (state/call args)
  nil)

# -- hashes ----------------------------------------------------------------

(defn hget
  "One field of a hash, decoded, or nil."
  [k field]
  (state/codec-decode (state/call ["HGET" (state/prefixed k) field])))

(defn hset
  ``Set hash fields: one field and value, or a whole dictionary.

      (redis/hset "user:1" :email "a@b.c")
      (redis/hset "user:1" {:email "a@b.c" :seen 3})

  Returns how many fields were new.``
  [k field-or-dict &opt v]
  (def args @["HSET" (state/prefixed k)])
  (if (nil? v)
    (eachp [f fv] field-or-dict
      (array/push args (resp/argument f))
      (array/push args (state/codec-encode fv)))
    (do (array/push args (resp/argument field-or-dict))
        (array/push args (state/codec-encode v))))
  (state/call args))

(defn hdel
  "Remove fields from a hash; returns how many existed."
  [k & fields]
  (if (empty? fields) 0 (state/call ["HDEL" (state/prefixed k) ;fields])))

(defn hgetall
  ``A whole hash as a table of field -> decoded value, or an empty
  table when there is no such key (redis does not distinguish an empty
  hash from a missing one — a hash with no fields does not exist).``
  [k]
  (def r (state/call ["HGETALL" (state/prefixed k)]))
  (def c (state/active-codec))
  (def out @{})
  # RESP3 answers with a map, RESP2 with the same pairs flattened
  (if (dictionary? r)
    (eachp [f v] r (put out f (codec/decode c v)))
    (loop [i :range [0 (length r) 2]]
      (put out (in r i) (codec/decode c (get r (inc i))))))
  out)

(defn hincr
  "Add `by` (default 1) to a hash field, and return the result."
  [k field &opt by]
  (default by 1)
  (state/call ["HINCRBY" (state/prefixed k) field by]))

(defn hkeys
  "The field names of a hash."
  [k]
  (state/call ["HKEYS" (state/prefixed k)]))

(defn hlen
  "How many fields a hash has."
  [k]
  (state/call ["HLEN" (state/prefixed k)]))

# -- lists -----------------------------------------------------------------

(defn lpush
  "Push values onto the head of a list; returns the new length."
  [k & vs]
  (state/call ["LPUSH" (state/prefixed k) ;(map state/codec-encode vs)]))

(defn rpush
  "Push values onto the tail of a list; returns the new length."
  [k & vs]
  (state/call ["RPUSH" (state/prefixed k) ;(map state/codec-encode vs)]))

(defn lpop
  "Take a value off the head of a list, decoded, or nil."
  [k]
  (state/codec-decode (state/call ["LPOP" (state/prefixed k)])))

(defn rpop
  "Take a value off the tail of a list, decoded, or nil."
  [k]
  (state/codec-decode (state/call ["RPOP" (state/prefixed k)])))

(defn llen
  "How long a list is."
  [k]
  (state/call ["LLEN" (state/prefixed k)]))

(defn lrange
  "A slice of a list, decoded. Indexes are redis': 0 and -1 are the
  whole list."
  [k start stop]
  (codec/decode-all (state/active-codec)
                    (state/call ["LRANGE" (state/prefixed k) start stop])))

(defn ltrim
  "Keep only the given slice of a list."
  [k start stop]
  (state/call ["LTRIM" (state/prefixed k) start stop])
  nil)

(defn blpop
  ``Take a value off the head of the first of `ks` that has one,
  waiting up to `timeout` seconds (0 waits forever). Returns
  [key value] with the key in the application's spelling, or nil when
  the wait ran out.

  The read timeout is lifted for the call — a blocking command is the
  one case where the connection is meant to sit silent, and a read
  timeout under it would break a connection that is doing exactly what
  it was told.``
  [ks &opt timeout]
  (default timeout 0)
  (def keys- (if (indexed? ks) ks [ks]))
  (def r (state/call ["BLPOP" ;(map state/prefixed keys-) timeout]
                     {:timeout (if (pos? timeout) (+ timeout 1) conn/no-timeout)}))
  (when r [(state/unprefixed (in r 0)) (state/codec-decode (in r 1))]))

(defn brpop
  "Like `blpop`, from the tail."
  [ks &opt timeout]
  (default timeout 0)
  (def keys- (if (indexed? ks) ks [ks]))
  (def r (state/call ["BRPOP" ;(map state/prefixed keys-) timeout]
                     {:timeout (if (pos? timeout) (+ timeout 1) conn/no-timeout)}))
  (when r [(state/unprefixed (in r 0)) (state/codec-decode (in r 1))]))

# -- sets ------------------------------------------------------------------

(defn sadd
  "Add members to a set; returns how many were new."
  [k & vs]
  (state/call ["SADD" (state/prefixed k) ;(map state/codec-encode vs)]))

(defn srem
  "Remove members from a set; returns how many were there."
  [k & vs]
  (state/call ["SREM" (state/prefixed k) ;(map state/codec-encode vs)]))

(defn smembers
  "Every member of a set, decoded."
  [k]
  (codec/decode-all (state/active-codec)
                    (state/call ["SMEMBERS" (state/prefixed k)])))

(defn smember?
  "Is this value in the set?"
  [k v]
  (def r (state/call ["SISMEMBER" (state/prefixed k) (state/codec-encode v)]))
  (if (boolean? r) r (pos? r)))

(defn scard
  "How many members a set has."
  [k]
  (state/call ["SCARD" (state/prefixed k)]))

# -- sorted sets -----------------------------------------------------------

(defn- score-of
  "A score as a number, whichever protocol answered: RESP3 sends a
  double, RESP2 the decimal text of one."
  [v]
  (if (number? v) v (scan-number (string v))))

(defn zadd
  ``Add scored members to a sorted set: one score and member, or a
  dictionary of member -> score.

      (redis/zadd "due" 1735689600 :job-17)
      (redis/zadd "due" {:job-17 1735689600 :job-18 1735689660})

  A sorted set keyed by a timestamp is how a delayed queue is
  built — which is why this one is here and the rest of the family is
  not.``
  [k score-or-dict &opt member]
  (def args @["ZADD" (state/prefixed k)])
  (if (nil? member)
    (eachp [m s] score-or-dict
      (array/push args s)
      (array/push args (state/codec-encode m)))
    (do (array/push args score-or-dict)
        (array/push args (state/codec-encode member))))
  (state/call args))

(defn zrem
  "Remove members from a sorted set."
  [k & vs]
  (state/call ["ZREM" (state/prefixed k) ;(map state/codec-encode vs)]))

(defn zscore
  "The score of one member, or nil."
  [k member]
  (def r (state/call ["ZSCORE" (state/prefixed k) (state/codec-encode member)]))
  (when r (score-of r)))

(defn zcard
  "How many members a sorted set has."
  [k]
  (state/call ["ZCARD" (state/prefixed k)]))

(defn zrange
  ``Members between two ranks, decoded, lowest score first.
  `{:withscores true}` returns [member score] pairs instead.

  RESP3 answers WITHSCORES with the pairs already paired and RESP2
  with them flattened; both come back the same shape from here.``
  [k start stop &opt opts]
  (default opts {})
  (def c (state/active-codec))
  (def r (state/call (if (opts :withscores)
                       ["ZRANGE" (state/prefixed k) start stop "WITHSCORES"]
                       ["ZRANGE" (state/prefixed k) start stop])))
  (cond
    (not (opts :withscores)) (codec/decode-all c r)
    (and (not (empty? r)) (indexed? (in r 0)))
    (seq [pair :in r] [(codec/decode c (in pair 0)) (score-of (in pair 1))])
    (seq [i :range [0 (length r) 2]]
      [(codec/decode c (in r i)) (score-of (get r (inc i)))])))

(defn zrange-by-score
  ``Members whose score falls between `min` and `max`, decoded. The
  bounds are redis': numbers, `"-inf"`/`"+inf"`, or `"(5"` for
  exclusive. `{:limit n}` caps how many come back — which is what
  turns "everything due" into "the next hundred due".``
  [k lo hi &opt opts]
  (default opts {})
  (def args @["ZRANGEBYSCORE" (state/prefixed k) lo hi])
  (when-let [n (opts :limit)]
    (array/push args "LIMIT")
    (array/push args (get opts :offset 0))
    (array/push args n))
  (codec/decode-all (state/active-codec) (state/call args)))

# -- scanning --------------------------------------------------------------

(defn scan-each
  ``Call `f` with every key matching `opts`, walking the keyspace with
  SCAN. Options: :match (a glob, prefixed like every other key),
  :count (how much work per round trip, a hint), :type ("hash",
  "zset", ...).

  SCAN and not KEYS on purpose: KEYS walks the whole keyspace inside
  the one thread that also serves every other client, and on a
  production database it is an outage. SCAN gives no snapshot in
  return — a key present throughout is returned at least once, one
  added or removed while the walk is running may or may not appear.``
  [f &opt opts]
  (default opts {})
  (def pattern (state/prefixed (get opts :match "*")))
  (var cursor "0")
  (var running true)
  (while running
    (def args @["SCAN" cursor "MATCH" pattern])
    (when-let [n (opts :count)] (array/push args "COUNT") (array/push args n))
    (when-let [t (opts :type)] (array/push args "TYPE") (array/push args t))
    (def r (state/call args))
    (def next-cursor (string (in r 0)))
    (each k (in r 1) (f (state/unprefixed k)))
    (set cursor next-cursor)
    (when (= "0" cursor) (set running false)))
  nil)

(defn matching-keys
  "Every key matching `opts` (see `scan-each`), collected into an
  array."
  [&opt opts]
  (def out @[])
  (scan-each |(array/push out $) opts)
  out)

# -- scripting -------------------------------------------------------------

(defn script
  ``A Lua script as a callable: loaded once, called by its digest, and
  reloaded transparently when the server has forgotten it (a restart,
  a SCRIPT FLUSH — the NOSCRIPT reply).

      (def take-one
        (redis/script `+++
          local v = redis.call('LPOP', KEYS[1])
          if v then redis.call('INCR', KEYS[2]) end
          return v +++))

      (take-one ["queue" "taken"] [])

  Keys are prefixed like every other helper's; arguments are not
  touched. A script is how two commands become one atomic step — redis
  runs it with nothing interleaved — and it is what a queue or a
  rate limiter is built out of.``
  [source]
  (var digest nil)
  (fn run-script [&opt keys- argv]
    (default keys- [])
    (default argv [])
    (def prefixed (map state/prefixed keys-))
    (defn invoke [sha]
      (state/call ["EVALSHA" sha (length prefixed) ;prefixed ;argv] {:raw true}))
    (unless digest (set digest (state/call ["SCRIPT" "LOAD" source])))
    (var r (invoke digest))
    (when (and (resp/error? r) (= "NOSCRIPT" (get r :code)))
      (set digest (state/call ["SCRIPT" "LOAD" source]))
      (set r (invoke digest)))
    (if (resp/error? r)
      (error (conn/command-error r ["EVALSHA"]))
      r)))

# -- the cache shape -------------------------------------------------------

(defn remember
  ``The value under `k`, or — when there is none — the result of
  `thunk`, stored for `ttl` seconds and returned.

      (redis/remember "rates" 300 (fn [] (fetch-rates)))

  Values go through the codec, so a table stays a table under `:jdn`
  and comes back a string under `:raw`. This is a cache, not a lock:
  two fibers that miss at the same time both call `thunk` and the
  second write wins. Where that matters, take a lock first —
  `(redis/set lock-key id {:nx true :ex 10})` is one.

  A `nil` from `thunk` is not stored: redis has no way to hold "this
  is genuinely absent" apart from not holding the key, so a nil would
  be recomputed every time either way, and storing "" would answer the
  next reader with the wrong thing.``
  [k ttl thunk]
  (def hit (get-key k))
  (if (nil? hit)
    (let [v (thunk)]
      (unless (nil? v) (set-key k v {:ex ttl}))
      v)
    hit))

(defn forget
  "Drop a cached key. The plural of `del`, spelled the way a cache
  reads."
  [& ks]
  (del-keys ;ks))

# -- server ----------------------------------------------------------------

(defn ping
  "PING the server. True, or a thrown connection error."
  []
  (def r (state/call ["PING"]))
  (or (= "PONG" r) (= "PONG" (get r 0))))

(def- info-peg
  # INFO is a text document: "# Section" headers, "key:value" lines,
  # CRLF endings, and a trailing blank line per section.
  (peg/compile
    ~(any (+ (* "#" (thru "\r\n"))
             (* '(some (if-not (set ":\r\n") 1)) ":" '(any (if-not "\r\n" 1)) "\r\n")
             "\r\n"))))

(defn server-info
  ``INFO as a table of string -> string. `section` narrows it
  ("server", "memory", "clients", "stats", "replication",
  "keyspace").``
  [&opt section]
  (def text (state/call (if section ["INFO" section] ["INFO"])))
  (def m (or (peg/match info-peg text) @[]))
  (def out @{})
  (loop [i :range [0 (length m) 2]]
    (put out (in m i) (get m (inc i))))
  out)

(defn dbsize
  "How many keys the selected database holds — the whole database,
  prefix or not."
  []
  (state/call ["DBSIZE"]))

(defn flushdb!
  ``Delete every key in the selected database. Every key: the prefix
  does not narrow this, because redis has no notion of one. For a
  prefixed subset, walk it — `(each k (redis/matching-keys {:match
  "*"}) (redis/del k))` — and for tests, give the test profile a
  database of its own.``
  []
  (state/call ["FLUSHDB"])
  nil)

# -- names that shadow the core ------------------------------------------
#
# Last, and deliberately: `get`, `set`, `keys` and `type` are core
# functions, and a module that shadows them before its own code is
# written is a module that cannot use them. Everything above is
# defined; from here nothing is.

(def get "See get-key — the value of a key, decoded." get-key)
(def set "See set-key — set a key, with :ex/:nx/:xx/:get." set-key)
(def del "See del-keys — delete keys." del-keys)
(def keys "See matching-keys — every key matching a glob, via SCAN." matching-keys)
(def type "See key-type — the type of a key, as a keyword." key-type)
(def ttl "See key-ttl — seconds to live, :none, or nil." key-ttl)
