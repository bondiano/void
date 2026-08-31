# The pure-data half: the property list, the topic spelling, the vu
# layout constants. No broker, and no librdkafka either — everything
# here must pass on a machine that has neither.

(import ../test-support/paths)
(import void/kafka/config :as config)
(import void/kafka/bus :as bus)
(import void/kafka/librdkafka :as rk)

# -- properties ----------------------------------------------------------

(def props (config/properties {:brokers ["a:9092" "b:9092"] :client-id "app"
                               :properties {"linger.ms" 5 "acks" "all"}}))
(defn- prop [name]
  (var out nil)
  (each [k v] props (when (= k name) (set out v)))
  out)

(assert (= "a:9092,b:9092" (prop "bootstrap.servers"))
        "a broker list joins the way the library reads it")
(assert (= "app" (prop "client.id")) "the client id travels")
(assert (= "5" (prop "linger.ms")) "a numeric property becomes the string the library parses")
(assert (= "all" (prop "acks")) "raw properties pass through under their own names")

(assert (= "one:1" (config/brokers {:brokers "one:1"})) "a single string stays one")
(assert (= "127.0.0.1:9092" (config/brokers {}))
        "the fallback is a real localhost, the void/db-mysql argument")

# precedence: [:properties] beats the computed base...
(def layered (config/properties {:properties {"auto.offset.reset" "latest"}}
                                {"auto.offset.reset" "earliest"}))
(var seen nil)
(each [k v] layered (when (= k "auto.offset.reset") (set seen v)))
(assert (= "latest" seen) "an operator who spells a property the library's way means it")

# ...but not the semantics
(def [forced err1]
  (protect (config/properties {:properties {"enable.auto.commit" "false"}}
                              {} {"enable.auto.commit" "true"})))
(assert (not forced) "a forced property cannot be overridden")
(assert (string/find "semantics" err1) "and the refusal says why")

# and never the event machinery
(def [reserved err2]
  (protect (config/properties {:properties {"dr_msg_cb" "boom"}})))
(assert (not reserved) "a reserved property is refused")
(assert (string/find "ADR-0035" err2) "naming the decision that owns it")

(assert (= 30000 (config/message-timeout-ms {})) "30 s, not the library's 300")
(assert (= 2500 (config/message-timeout-ms {:message-timeout 2.5})) "seconds in, milliseconds out")
(assert (config/verify? {}) "the boot probe is on unless turned off")
(assert (not (config/verify? {:verify false})))

# no secret in the log line
(def desc (config/describe {:brokers "b:1" :properties {"sasl.password" "s3cret"}}))
(assert (nil? (string/find "s3cret" (string/format "%q" desc)))
        "describe never carries a property value")

# -- topic spelling ------------------------------------------------------

(assert (= "user.created" (bus/kafka-topic "" :user/created))
        "the / becomes a dot")
(assert (= "shop.user.created" (bus/kafka-topic "shop." :user/created))
        "and the prefix goes in front")
(assert (= :user/created (bus/bus-topic "" "user.created")) "and comes back")
(assert (= :user/created (bus/bus-topic "shop." "shop.user.created"))
        "prefix stripped")
(assert (= :their.topic (bus/bus-topic "shop." "their.topic"))
        "a topic outside our prefix keeps its own spelling")

(def [dotted err3] (protect (bus/kafka-topic "" :user.created)))
(assert (not dotted) "a literal dot is refused — it would collide with the mapping")
(assert (string/find "ADR-0035" err3))

(assert (deep= ["shop.a.b" "shop.c"]
               (bus/subscription "shop." [:a/b :c] [:a/b :c]))
        "a fully exact hint subscribes exact names")
(assert (deep= ["^shop\\..*"]
               (bus/subscription "shop." nil ["a/*"]))
        "a wildcard hint subscribes the prefix as a regex, dot escaped")
(assert (deep= ["^.*"] (bus/subscription "" nil ["*"]))
        "no prefix, everything — the router filters on arrival")

# -- the layouts the ffi writes ------------------------------------------
#
# The constants the header promises (ADR-0035): the vu union starts at
# 8 and is padded to 64, so the stride is 72 — same number as the
# documented rd_kafka_message_t. A change here is a change to the
# library's ABI promise, not a refactor.

(assert (= 72 rk/vu-size) "rd_kafka_vu_t: 4 vtype + 4 pad + 64 union")
(assert (= 64 (get rk/message-offsets :private))
        "the DR token comes back from _private at 64")
(assert (= 0x200000 (get rk/events :describe-cluster-result))
        "the boot probe's event bit")

# the writers actually write where they claim
(def buf (rk/vu-buffer 2))
(rk/vu-msgflags! buf 0 rk/MSG-F-COPY)
# int/u64 in the test because a janet number literal this large is a
# double; real tokens are counter-minted and stay far below 2^53
(rk/vu-opaque! buf 1 (int/u64 "0x1122334455667788"))
(assert (= (rk/vtypes :msgflags) (ffi/read :int buf 0)))
(assert (= rk/MSG-F-COPY (ffi/read :int buf 8)))
(assert (= (rk/vtypes :opaque) (ffi/read :int buf 72)))
(assert (= (int/u64 "0x1122334455667788") (ffi/read :uint64 buf 80))
        "the token lands in the second entry's union slot")

(print "config-test: OK")
