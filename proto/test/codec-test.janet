(import ../test-support/paths)
(import void/proto :as proto)
(import void/proto/codec :as codec)
(import void/proto/descriptor :as desc)

(defn- hex [bs] (string/join (map |(string/format "%02x" $) bs) ""))
(defn- unhex [s]
  (string/from-bytes
    ;(seq [i :range [0 (length s) 2]]
       (scan-number (string "0x" (string/slice s i (+ i 2)))))))

# The golden byte strings below were printed by protoc:
#
#     protoc --encode=t.Wide y.proto < y.txt | xxd -p
#
# so this file is not "the codec agrees with itself" — it is the codec
# agreeing with the reference implementation, byte for byte, which is
# the only claim worth making about a wire format (ADR-0013).

(proto/defenum :t/Kind {:KIND_UNSET 0 :KIND_ONE 1})
(proto/defmessage :t/Inner {:s [1 :string]})
(proto/defmessage :t/Wide
  {:i32 [1 :int32] :i64 [2 :int64] :u32 [3 :uint32] :u64 [4 :uint64]
   :s32 [5 :sint32] :s64 [6 :sint64] :f32 [7 :fixed32] :f64 [8 :fixed64]
   :sf32 [9 :sfixed32] :sf64 [10 :sfixed64] :b [11 :bool] :s [12 :string]
   :by [13 :bytes] :fl [14 :float] :db [15 :double] :k [16 :t/Kind]
   :in [17 :t/Inner] :packed [18 :repeated :int32] :strs [19 :repeated :string]
   :m [20 :map :int32 :t/Inner] :opt [21 :optional :int32]
   :a [22 :int32 {:oneof :choice}] :bb [23 :string {:oneof :choice}]})

(def wide
  {:i32 -1 :i64 -2 :u32 4294967295 :u64 (int/u64 "18446744073709551615")
   :s32 -1 :s64 -2 :f32 7 :f64 8 :sf32 -9 :sf64 -10 :b true :s "hello"
   :by "\x01\x02" :fl 1.5 :db -2.5 :k :KIND_ONE :in {:s "deep"}
   :packed [1 2 300] :strs ["a" "b"] :m {5 {:s "v"}} :opt 0 :bb "pick"})

(def wide-golden
  (string "08ffffffffffffffffff0110feffffffffffffffff0118ffffffff0f20ffffff"
          "ffffffffffff01280130033d070000004108000000000000004df7ffffff51f6"
          "ffffffffffffff5801620568656c6c6f6a020102750000c03f79000000000000"
          "04c08001018a01060a04646565709201040102ac029a0101619a010162a20107"
          "080512030a0176a80100ba01047069636b"))

(assert (= wide-golden (hex (proto/encode :t/Wide wide)))
        "every scalar protobuf has, encoded exactly as protoc encodes it")

(def back (proto/decode :t/Wide (unhex wide-golden)))
(assert (= -1 (back :i32)))
(assert (= 4294967295 (back :u32)))
(assert (= 0 (compare (int/u64 "18446744073709551615") (back :u64)))
        "a uint64 nobody can hold in a double comes back as an int/u64")
(assert (= -2 (back :s64)))
(assert (= -10 (back :sf64)))
(assert (= 1.5 (back :fl)))
(assert (= -2.5 (back :db)))
(assert (= :KIND_ONE (back :k)) "an enum comes back as its name")
(assert (= "deep" (get-in back [:in :s])))
(assert (deep= @[1 2 300] (back :packed)))
(assert (= "v" (get-in back [:m 5 :s])) "a map key keeps its type")
(assert (= "pick" (back :bb)))
(assert (nil? (back :a)) "the other member of the oneof is not there at all")
(assert (= wide-golden (hex (proto/encode :t/Wide back)))
        "and re-encoding what protoc wrote produces what protoc wrote")

# -- proto3 presence ------------------------------------------------------

(proto/defmessage :t/Presence
  {:n [1 :int32] :s [2 :string] :maybe [3 :optional :int32]
   :inner [4 :t/Inner] :list [5 :repeated :int32] :k [6 :t/Kind]})

(assert (empty? (proto/encode :t/Presence {}))
        "a message of nothing but defaults is zero bytes")
(assert (empty? (proto/encode :t/Presence {:n 0 :s "" :list [] :k :KIND_UNSET}))
        "and so is one whose every field was set to its default — that is implicit presence")
(assert (= "1800" (hex (proto/encode :t/Presence {:maybe 0})))
        "an `optional` field writes its zero, because for it zero is not absence")
(assert (= "2200" (hex (proto/encode :t/Presence {:inner {}})))
        "and an empty message field is two bytes rather than none")

(def empty-back (proto/decode :t/Presence ""))
(assert (= 0 (empty-back :n)))
(assert (= "" (empty-back :s)))
(assert (deep= @[] (empty-back :list)))
(assert (= :KIND_UNSET (empty-back :k)) "an absent enum decodes to its zero-numbered name")
(assert (nil? (empty-back :maybe)) "and an absent `optional` field decodes to nothing")
(assert (nil? (empty-back :inner)) "as does an absent message")

# -- a oneof holds one ----------------------------------------------------

(def [ok err] (protect (proto/encode :t/Wide {:a 1 :bb "two"})))
(assert (not ok))
(assert (string/find "oneof" err) "two members of one oneof is refused, and by name")

(assert (nil? ((proto/decode :t/Wide (unhex "b00101ba01047069636b")) :a))
        "on the wire the last member to arrive clears the others")

# -- unknown fields survive -----------------------------------------------

(proto/defmessage :t/Old {:kept [1 :string]})
(proto/defmessage :t/New {:kept [1 :string] :added [2 :int32] :also [3 :string]})

(def new-bytes (proto/encode :t/New {:kept "a" :added 7 :also "b"}))
(def through-old (proto/decode :t/Old new-bytes))
(assert (= "a" (through-old :kept)))
(assert (not (nil? (through-old :proto/unknown)))
        "a reader that never heard of :added keeps its bytes")
(assert (= (hex new-bytes) (hex (proto/encode :t/Old through-old)))
        "and hands them back untouched — read-modify-write through an old peer loses nothing")
(def round-tripped (proto/decode :t/New (proto/encode :t/Old through-old)))
(assert (= 7 (round-tripped :added)))
(assert (= "b" (round-tripped :also)))

# -- concatenation is the merge -------------------------------------------

(def first-half (proto/encode :t/Wide {:s "one" :packed [1] :in {:s "a"}}))
(def second-half (proto/encode :t/Wide {:s "two" :packed [2]}))
(def merged (proto/decode :t/Wide (string first-half second-half)))
(assert (= "two" (merged :s)) "a singular field takes the last value")
(assert (deep= @[1 2] (merged :packed)) "a repeated field accumulates")
(assert (= "a" (get-in merged [:in :s])) "and a nested message merges rather than replacing")

# -- what the encoder refuses ---------------------------------------------

(defn- refused [f why]
  (def [ok err] (protect (f)))
  (assert (not ok) why)
  err)

(assert (string/find "int32"
                     (refused |(proto/encode :t/Wide {:i32 2147483648})
                              "an int32 that is not one is refused"))
        "and the message says which type it did not fit")
(refused |(proto/encode :t/Wide {:i32 "seven"}) "a string is not an integer")
(refused |(proto/encode :t/Wide {:u32 -1}) "an unsigned field refuses a negative value")
(refused |(proto/encode :t/Wide {:k :KIND_NOPE}) "an enum refuses a name it does not have")
(refused |(proto/encode :t/Wide {:packed 5}) "a repeated field refuses a scalar")
(refused |(proto/encode :t/Wide {:in "not a message"}) "a message field refuses a string")

# -- a message from the network is a stranger -----------------------------

(proto/defmessage :t/Nest {:next [1 :t/Nest]})
(var deep @{})
(loop [_ :range [0 100]] (set deep @{:next deep}))
(refused |(proto/encode :t/Nest deep) "a hundred levels of nesting is refused rather than run")

(var bomb "")
(loop [_ :range [0 100]] (set bomb (string "\x0a" (string/from-bytes (length bomb)) bomb)))
(refused |(proto/decode :t/Nest bomb) "and so is a hundred levels arriving from outside")

# -- the descriptor is checked when it is written, not when it is used ----

(refused |(desc/message :t/Bad {:a [1 :string] :b [1 :int32]})
         "two fields cannot claim one number")
(refused |(desc/message :t/Bad {:a [0 :string]}) "field 0 does not exist")
(refused |(desc/message :t/Bad {:a [19001 :string]}) "19000-19999 belong to protobuf")
(refused |(desc/message :t/Bad {:a [1 :map :double :string]}) "a double is not a map key")
(refused |(desc/enum :t/Bad {:one 1}) "an enum without a zero cannot say \"unset\"")

(print "codec ok")
