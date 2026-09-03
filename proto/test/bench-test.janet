(import ../test-support/paths)
(import void/proto :as proto)

### The bench line this package owes: pure-Janet protobuf on a large
### payload can become CPU-bound, and a package that can must carry a
### bench row in its suite.
###
### It prints rather than gates. Absolute numbers on a shared CI runner
### mean nothing (is explicit about it: the thresholds in this repository
### are *relative*, head against merge-base on one machine), so what is
### asserted here is that the payload survives the trip; what is printed
### is the number a person comparing two commits reads. The shape is
### deliberately the unfriendly one — a list of nested messages with
### strings in them, which is what an RPC response actually is.

(proto/defmessage :bench/Line
  {:sku [1 :string] :title [2 :string] :price_cents [3 :int64] :quantity [4 :int32]})
(proto/defmessage :bench/Order
  {:id [1 :string] :total_cents [2 :int64] :lines [3 :repeated :bench/Line]
   :labels [4 :map :string :string]})

(def order
  {:id "01J8ZQ3V9K7W2X6Y4B5N8M0P1Q"
   :total_cents 1049500
   :lines (seq [i :range [0 50]]
            {:sku (string/format "SKU-%05d" i)
             :title (string "A product with a reasonably long title, number " i)
             :price_cents (* 995 (inc i))
             :quantity (+ 1 (% i 7))})
   :labels {"channel" "web" "warehouse" "lis-1" "priority" "standard"}})

(def payload (proto/encode :bench/Order order))
(def json-payload (proto/encode-json :bench/Order order))

(assert (= 50 (length ((proto/decode :bench/Order payload) :lines)))
        "the payload the benchmark measures is one that round-trips")

(defn- rate [what n f]
  (def start (os/clock))
  (loop [_ :range [0 n]] (f))
  (def elapsed (max 1e-9 (- (os/clock) start)))
  (printf "  %-24s %8.0f ops/s  %8.2f MB/s"
          what (/ n elapsed) (/ (* n (length payload)) elapsed 1048576))
  (/ n elapsed))

(def rounds 200)
(print "void/proto — " (length payload) " bytes protobuf, "
       (length json-payload) " bytes proto3-JSON (" rounds " rounds):")
(def numbers
  [(rate "encode (protobuf)" rounds |(proto/encode :bench/Order order))
   (rate "decode (protobuf)" rounds |(proto/decode :bench/Order payload))
   (rate "encode (proto3 JSON)" rounds |(proto/encode-json :bench/Order order))
   (rate "decode (proto3 JSON)" rounds |(proto/decode-json :bench/Order json-payload))])

(each n numbers
  (assert (and (> n 0) (not= n math/inf)) "every measurement is a number"))

(print "bench ok")
