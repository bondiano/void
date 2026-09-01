# The notification value: what it must carry, what it refuses, and the
# two decisions worth a test of their own — the bare-address shorthand
# and the per-channel override.

(import ../test-support/paths)
(import void/notify/notification :as notification)

# -- what a notification must say ----------------------------------------

(each [note reason]
  [[{:title "no key" :to {:email "a@b.co"}} "a notification without a :key"]
   [{:key "order/shipped" :title "t" :to {:email "a@b.co"}} "a :key that is not a keyword"]
   [{:key :x :to {:email "a@b.co"}} "a notification without a :title"]
   [{:key :x :title "" :to {:email "a@b.co"}} "an empty :title"]
   [{:key :x :title "t"} "a notification with no :to at all"]
   [{:key :x :title "t" :to {"email" "a@b.co"}} ":to keyed by a string"]
   [{:key :x :title "t" :to {:email "a@b.co"} :data [1 2]} ":data that is not a table"]
   ["not a table" "something that is not a table"]]
  (assert (not (first (protect (notification/normalize note [:mail]))))
          (string reason " is refused")))

# -- the normalized value ------------------------------------------------

(def note
  (notification/normalize
    {:key :order/shipped
     :title "Your order shipped"
     :body "Order #1042 is on its way."
     :url "/orders/1042"
     :data {:order 1042}
     :to {:email "ada@example.com" :subject "user:42"}
     :mail {:subject "Order #1042 is on its way"}
     :webhook {:url "https://hooks.example.com/void"}}
    [:mail :inapp]
    {:id "ntf_test" :at 1756400000}))

(assert (notification/normalized? note))
(assert (= "ntf_test" (note :id)) "the id is handed in, so a test compares values")
(assert (= 1756400000 (note :at)))
(assert (deep= [:mail :inapp] (note :channels)))
(assert (= "Order #1042 is on its way" (get-in note [:overrides :mail :subject])))
(assert (nil? (get-in note [:overrides :webhook]))
        "only the channels this notification goes to carry their overrides into the payload — what is not delivered is not queued")

(assert (= "ada@example.com" (notification/address-for note {:address :email})))
(assert (= "user:42" (notification/address-for note {:address :subject})))
(assert (nil? (notification/address-for note {:address :url}))
        "a channel whose address is not in :to gets nil — which is how it says \"not mine\"")
(assert (nil? (notification/address-for note {}))
        "and a channel that declares no address never reads one off the notification")

(assert (deep= {:subject "Order #1042 is on its way"} (notification/override-for note :mail)))
(assert (deep= {} (notification/override-for note :inapp))
        "a channel the notification said nothing about gets an empty override, not nil")

(assert (string/find "order/shipped" (notification/summary note)))
(assert (string/find "ntf_test" (notification/summary note)))

# -- the bare address ----------------------------------------------------

(def single
  (notification/normalize {:key :x :title "t" :to "ada@example.com"} [:mail]))
(assert (= "ada@example.com" (notification/address-for single {:address :email}))
        "one channel, one address: the shorthand is unambiguous and is read by whichever key that channel asks for")
(assert (= "ada@example.com" (notification/address-for single {:address :subject}))
        "including a key it does not literally carry — with one channel there is nothing else it could mean")

(def [ok err]
  (protect (notification/normalize {:key :x :title "t" :to "ada@example.com"}
                                   [:mail :inapp])))
(assert (not ok) "a bare address with several channels is refused")
(assert (string/find "which of them" (string err))
        "and the message says why: a string says nothing about which channel it is for")

# -- ids are unique ------------------------------------------------------

(def a (notification/make-id))
(def b (notification/make-id))
(assert (not= a b))
(assert (string/has-prefix? "ntf_" a))
