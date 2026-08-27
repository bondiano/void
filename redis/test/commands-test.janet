(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/redis :as redis)
(import void/redis/conn :as conn)
(import void/redis/pool :as pool)
(import void/redis/state :as state)

(log/set-level! "void.redis" :error)
# the command funnel logs the failures this suite causes on purpose
(log/set-level! "void.redis.command" :fatal)

(if-not (server/available?)
  (server/skip "commands-test")
  (server/with-client* "commands" {:codec :jdn}
    (fn [client]
      (defer (server/clean! redis/scan-each redis/del)

        # -- prefixing -------------------------------------------------
        #
        # The prefix is what lets one database hold two applications —
        # and this suite hold its keys apart from another checkout's.

        (assert (string/has-prefix? (server/prefix "commands") (redis/redis-key "k"))
                "a helper's key reaches the server prefixed")
        (redis/set "k" "v")
        (assert (not (nil? (redis/command "GET" (redis/redis-key "k"))))
                "which is where the raw surface finds it")
        (assert (nil? (redis/command "GET" "k"))
                "and not where an unprefixed command looks")
        (assert (= "\"v\"" (redis/command "GET" (redis/redis-key "k")))
                "and what it finds is the encoded form: the raw surface runs no codec")
        (assert (index-of "k" (redis/keys {:match "*"}))
                "keys come back in the application's spelling")
        (redis/del "k")

        # -- values through the codec ----------------------------------

        (redis/set "session" @{:user 7 :roles [:admin]})
        (def back (redis/get "session"))
        (assert (= 7 (back :user)) "a table survives the round trip under :jdn")
        (assert (= :admin (get-in back [:roles 0])) "keywords and all")
        (assert (nil? (redis/get "nothing")) "a missing key is nil, not an error")

        # -- expiry ------------------------------------------------------

        (assert (redis/set "ttl-key" "v" {:ex 60}))
        (def t (redis/ttl "ttl-key"))
        (assert (and (number? t) (<= t 60) (> t 55)) "SET EX sets a time to live")
        (redis/persist "ttl-key")
        (assert (= :none (redis/ttl "ttl-key"))
                "a key with no expiry says :none rather than -1")
        (assert (nil? (redis/ttl "never-existed"))
                "and a key that does not exist says nil rather than -2")
        (assert (= :string (redis/type "ttl-key")))
        (assert (nil? (redis/type "never-existed")))

        # -- set as a lock -----------------------------------------------

        (redis/del "lock")
        (assert (redis/set "lock" "me" {:nx true :ex 30}) "NX takes the lock")
        (assert (not (redis/set "lock" "you" {:nx true :ex 30}))
                "and the second caller is told it did not")
        (assert (= "me" (redis/get "lock")) "the first value stands")
        (redis/del "lock")

        # -- counters ----------------------------------------------------

        (redis/del "n")
        (assert (= 1 (redis/incr "n")) "a counter starts at zero without being created")
        (assert (= 11 (redis/incr "n" 10)))
        (assert (= 10 (redis/decr "n")))
        (redis/del "n")

        # -- hashes ------------------------------------------------------

        (redis/del "h")
        (assert (= 2 (redis/hset "h" {:email "a@b.c" :visits 3})) "a whole dictionary at once")
        (assert (= "a@b.c" (redis/hget "h" :email)))
        (def all (redis/hgetall "h"))
        (assert (= 3 (all "visits")) "a hash comes back a table of decoded values")
        (assert (= 2 (redis/hlen "h")))
        (assert (= 1 (redis/hdel "h" "email")))
        (assert (deep= @{} (redis/hgetall "no-such-hash"))
                "a hash that does not exist is an empty table — redis draws no distinction")
        (redis/del "h")

        # -- lists -------------------------------------------------------

        (redis/del "l")
        (redis/rpush "l" {:job 1} {:job 2})
        (assert (= 2 (redis/llen "l")))
        (assert (= 1 (get-in (redis/lrange "l" 0 -1) [0 :job])) "values decode on the way out")
        (assert (= 1 ((redis/lpop "l") :job)))
        (def [popped-key popped] (redis/blpop "l" 1))
        (assert (= "l" popped-key) "a blocking pop names the key in the application's spelling")
        (assert (= 2 (popped :job)))
        (assert (nil? (redis/blpop "l" 1)) "and answers nil when the wait runs out")

        # -- sets and sorted sets ----------------------------------------

        (redis/del "s" "z")
        (redis/sadd "s" :a :b :a)
        (assert (= 2 (redis/scard "s")) "a set holds each member once")
        (assert (redis/smember? "s" :a))
        (assert (not (redis/smember? "s" :c)))
        (redis/zadd "z" {:job-1 100 :job-2 200})
        (assert (= 100 (redis/zscore "z" :job-1)))
        (assert (deep= @[:job-1] (redis/zrange-by-score "z" "-inf" 150))
                "a sorted set keyed by a timestamp is a delayed queue")
        (assert (deep= @[[:job-1 100] [:job-2 200]] (redis/zrange "z" 0 -1 {:withscores true})))
        (redis/del "s" "z")

        # -- scanning ----------------------------------------------------

        (each i (range 30) (redis/set (string "scan:" i) i))
        (assert (= 30 (length (redis/keys {:match "scan:*"})))
                "SCAN walks a prefix without KEYS blocking the server")
        (assert (= 30 (length (redis/keys {:match "scan:*" :count 3})))
                "over as many round trips as it takes")
        (redis/del ;(redis/keys {:match "scan:*"}))

        # -- pipelining --------------------------------------------------

        (redis/del "p")
        (def replies (redis/pipeline [["INCR" (redis/redis-key "p")]
                                      ["INCR" (redis/redis-key "p")]]))
        (assert (deep= @[1 2] replies) "one round trip, both answers")
        (redis/del "p")

        # -- scripts -----------------------------------------------------

        (def take-one
          (redis/script `
            local v = redis.call('LPOP', KEYS[1])
            if v then redis.call('INCR', KEYS[2]) end
            return v`))
        (redis/del "q" "taken")
        # pushed raw: a script sees the bytes redis holds, not what a
        # codec would have made of them on the way out
        (redis/command "RPUSH" (redis/redis-key "q") "only")
        (assert (= "only" (take-one ["q" "taken"])) "a script runs, with its keys prefixed")
        (assert (= 1 (redis/incr "taken" 0)) "and its side effect landed on the prefixed key")
        (assert (nil? (take-one ["q" "taken"])) "a second call finds the list empty")
        (assert (= 1 (redis/incr "taken" 0)) "and did not count")
        (redis/del "q" "taken")

        # a forgotten script reloads itself rather than failing
        (redis/command "SCRIPT" "FLUSH")
        (redis/command "RPUSH" (redis/redis-key "q") "again")
        (assert (= "again" (take-one ["q" "taken"]))
                "after SCRIPT FLUSH the digest is stale — and reloaded transparently")
        (redis/del "q" "taken")

        # -- remember ----------------------------------------------------

        (redis/del "memo")
        (var calls 0)
        (defn compute [] (++ calls) {:answer 42})
        (assert (= 42 ((redis/remember "memo" 30 compute) :answer)))
        (assert (= 42 ((redis/remember "memo" 30 compute) :answer)))
        (assert (= 1 calls) "the second read is the cache")
        (redis/forget "memo")
        (redis/remember "memo" 30 compute)
        (assert (= 2 calls) "and forgetting brings the thunk back")

        (redis/del "nil-memo")
        (assert (nil? (redis/remember "nil-memo" 30 (fn [] nil))))
        (assert (not (redis/exists? "nil-memo"))
                "a nil is not stored: redis cannot hold \"genuinely absent\"")
        (redis/del "memo")

        # -- errors ------------------------------------------------------

        (redis/set "str" "text")
        (def [ok err] (protect (redis/lpush "str" "x")))
        (assert (not ok) "a wrong-type command fails")
        (assert (= "WRONGTYPE" (redis/error-code err)) "with the code, not just a message")
        (assert (= "text" (redis/get "str")) "and the connection carries on")
        (redis/del "str")

        # -- the pool ------------------------------------------------------
        #
        # Size two, four fibers: two run, two wait, and every one of
        # them gets an answer.

        (def sup (ev/chan 4))
        (each i (range 4)
          (ev/go (fn [] (redis/incr "pooled")) nil sup))
        (each _ (range 4) (ev/take sup))
        (assert (= 4 (redis/incr "pooled" 0)) "four fibers, four increments, two connections")
        (def stats (pool/stats (client :pool)))
        (assert (<= (stats :created) 8) "and no more connections than the pool allows")
        (redis/del "pooled")

        # -- a connection the server closed --------------------------------
        #
        # The commonest failure in production: an idle socket the server
        # tidied up. It is indistinguishable from a healthy one until
        # something is written to it, so the client has to retry.

        (def victim (pool/checkout (client :pool)))
        (def victim-id (get (conn/info victim) :client-id))
        (pool/checkin (client :pool) victim)
        (when victim-id
          (redis/command "CLIENT" "KILL" "ID" victim-id)
          (assert (= 1 (redis/incr "after-kill"))
                  "a command on the killed connection succeeds anyway — reopened and retried")
          (redis/del "after-kill"))

        (printf "commands-test: ok")))))
