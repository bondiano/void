(import ../test-support/paths)
(import void/proto :as proto)
(import void/proto/parse :as parse)
(import void/proto/descriptor :as desc)

(defn- refused [source why]
  (def [ok err] (protect (parse/parse source "<test>")))
  (assert (not ok) why)
  (if (string? err) err (string/format "%q" err)))

# -- a real file, with a real import graph --------------------------------
#
# test/protos/orders.proto is the fixture, and `protoc` compiles it —
# so what this suite reads is a .proto rather than a subset of one.

(def file (parse/load "test/protos/orders.proto"))

(assert (= "proto3" (file :syntax)))
(assert (= "shop.orders" (file :package)))
(assert (deep= ["google/protobuf/timestamp.proto" "shop/catalog.proto"] (file :imports)))
(assert (= "com.example.shop" (get-in file [:options :java_package]))
        "a file option nobody reads is still kept, so a later projection can")

(assert (desc/lookup :shop.catalog/Product)
        "an imported file was loaded and registered, next to the importing one")
(assert (desc/lookup :google.protobuf/Timestamp)
        "and google/protobuf/timestamp.proto resolved without a file on disk")

(def order (desc/message! :shop.orders/Order))
(assert (= "shop.orders.Order" (order :proto-name)))
(assert (= :string (get-in order [:by-name :id :type])))
(assert (= 2 (get-in order [:by-name :total_cents :number])))
(assert (= "total" (get-in order [:by-name :total_cents :json-name]))
        "json_name = \"total\" is the field's JSON name, not a comment")
(assert (= :repeated (get-in order [:by-name :lines :label])))
(assert (= :shop.orders/Line (get-in order [:by-name :lines :ref]))
        "an unqualified type resolves inside the package it was written in")
(assert (= :map (get-in order [:by-name :labels :label])))
(assert (= :optional (get-in order [:by-name :note :label])))
(assert (= :shop.orders/Status (get-in order [:by-name :status :ref])))
(assert (= :google.protobuf/Timestamp (get-in order [:by-name :placed_at :ref]))
        "and a fully-qualified one resolves across packages")
(assert (deep= [:card_token :on_account] (get-in order [:oneofs :payment])))
(assert (= :payment (get-in order [:by-name :card_token :oneof])))
(assert (= :shop.orders.Order/Address (get-in order [:by-name :ship_to :ref]))
        "a nested message is found from the scope it was written in, and keeps the full name")

(def line (desc/message! :shop.orders/Line))
(assert (= :shop.catalog/Product (get-in line [:by-name :product :ref]))
        "a type from an imported package resolves through the registry")

(def status (desc/enum! :shop.orders/Status))
(assert (= :STATUS_UNKNOWN (status :zero)))
(assert (= 2 (get-in status [:values :STATUS_SHIPPED])))

(def svc (desc/service! :shop.orders/OrderService))
(assert (= 3 (length (svc :methods))))
(assert (= :shop.orders/GetOrderRequest (get-in svc [:by-name :GetOrder :input])))
(assert (= :shop.orders/Order (get-in svc [:by-name :GetOrder :output])))
(assert (get-in svc [:by-name :GetOrder :idempotent])
        "idempotency_level = NO_SIDE_EFFECTS is what void/grpc reads to allow GET")
(assert (not (get-in svc [:by-name :PlaceOrder :idempotent])))
(assert (not (get-in svc [:by-name :GetOrder :server-streaming])))

# loading the same file twice does not parse it twice — and cannot
# loop on a cycle, which protobuf permits
(assert (= (file :package) ((parse/load "test/protos/orders.proto") :package)))

# -- comments, and the shapes of whitespace -------------------------------

(def terse (parse/parse "syntax='proto3';message M{string a=1;int32 b=2;}" "<terse>"))
(assert (= 1 (length (terse :descriptors))) "a file with no whitespace parses")

(def commented
  (parse/parse
    ``syntax = "proto3"; // trailing
      /* a block
         comment */
      message M { string a = 1; /* inline */ int32 b = 2; }``
    "<commented>"))
(assert (= 2 (length (get-in commented [:descriptors 0 :fields]))))

# -- proto3, and only proto3 ----------------------------------------------

(assert (string/find "proto3" (refused `syntax = "proto2"; message M { }`
                                       "a proto2 file is refused"))
        "and the refusal says which dialect this parser speaks")
(assert (string/find "proto3" (refused `message M { }` "a file with no syntax line is proto2"))
        "a missing syntax line means proto2, which is what the specification says")
(assert (string/find "required"
                     (refused `syntax = "proto3"; message M { required string a = 1; }`
                              "a required field is refused")))
(assert (string/find "group"
                     (refused `syntax = "proto3"; message M { repeated group G = 1 { string a = 1; } }`
                              "a group is refused")))
(assert (string/find "extension"
                     (refused `syntax = "proto3"; message M { extensions 100 to 199; }`
                              "an extension range is refused")))
(assert (string/find "default"
                     (refused `syntax = "proto3"; message M { string a = 1 [default = "x"]; }`
                              "a field default is refused")))

# -- what the parser cannot make sense of ---------------------------------

(refused `syntax = "proto3"; message M { string a = 1 }` "a missing semicolon is a parse error")
(refused `syntax = "proto3"; message M {` "an unclosed message is a parse error")
(assert (string/find "Missing"
                     (refused `syntax = "proto3"; message M { Missing m = 1; }`
                              "a type nobody defined is an error at parse time"))
        "and the error names the type rather than failing at encode")

# -- the tree, before it means anything -----------------------------------

(def tree (parse/tokens `syntax = "proto3"; package p; message M { string a = 1; }` "<t>"))
(assert (= "proto3" (tree :syntax)))
(assert (= :package (first (get-in tree [:statements 0]))))
(assert (= :message (first (get-in tree [:statements 1]))))

# -- and the descriptors it produces are the ones the codec wants ---------

(def payload (proto/encode :shop.orders/Order
                           {:id "A-1" :total_cents 990
                            :lines [{:product {:sku "s" :title "t" :price_cents 495}
                                     :quantity 2}]
                            :status :STATUS_PLACED
                            :placed_at {:seconds 1000000}
                            :ship_to {:city "Lisbon" :street "Rua"}
                            :card_token "tok"}))
(def read-back (proto/decode :shop.orders/Order payload))
(assert (= "A-1" (read-back :id)))
(assert (= 495 (get-in read-back [:lines 0 :product :price_cents])))
(assert (= :STATUS_PLACED (read-back :status)))
(assert (= "Lisbon" (get-in read-back [:ship_to :city])))
(assert (= "tok" (read-back :card_token)))
(assert (nil? (read-back :on_account)))
(assert (= "990" (get (proto/to-json :shop.orders/Order read-back) "total"))
        "and the JSON name the file gave the field is the one that comes out")

(print "parse ok")
