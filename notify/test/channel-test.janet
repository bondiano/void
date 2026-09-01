# The channel contract: what a contribution must be, what :project
# means when it is absent, and the two channels the kernel ships.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/notify/channel :as channel)
(import void/notify/notification :as notification)

(log/set-level! "void" :error)

(defn- note [&opt to]
  (notification/normalize {:key :x :title "hi" :to (or to {:email "ada@example.com"})}
                          [:memory]
                          {:id "ntf_1" :at 1756400000}))

# -- the contract --------------------------------------------------------

(each [contribution reason]
  [[{:deliver (fn [_] nil)} "a channel without a name"]
   [{:name :x} "a channel that cannot deliver"]
   [{:name "x" :deliver (fn [_] nil)} "a name that is not a keyword"]
   [{:name :x :deliver (fn [_] nil) :project :not-a-function} "a :project that is not a function"]
   [{:name :x :deliver (fn [_] nil) :address "email"} "an :address that is not a keyword"]]
  (assert (not (first (protect (channel/normalize contribution))))
          (string reason " is refused at boot")))

(def normalized (channel/normalize {:name :x :deliver (fn [_] nil)}))
(each key [:doc :address :project :permanent?]
  (assert (nil? (normalized key)) "the optional halves are filled in, not left missing"))

# -- projection ----------------------------------------------------------

(assert (deep= (note) (channel/project normalized (note)))
        "a channel without a :project is delivered the notification itself")

(def picky (channel/normalize {:name :y :deliver (fn [_] nil)
                               :project (fn [n] (when (get-in n [:to :email]) {:id (n :id)}))}))
(assert (nil? (channel/project picky (note {:subject "user:42"})))
        "a projection that returns nil is how a channel says the notification was not its business")

# -- permanence ----------------------------------------------------------

(assert (not (channel/permanent? normalized {:status 404}))
        "a channel that does not answer gets the retry")
(def final (channel/normalize {:name :z :deliver (fn [_] nil)
                               :permanent? (fn [err] (= 404 (get err :status)))}))
(assert (channel/permanent? final {:status 404}))
(assert (not (channel/permanent? final {:status 503})))
(assert (not (channel/permanent? (channel/normalize {:name :w :deliver (fn [_] nil)
                                                     :permanent? (fn [_] (error "boom"))})
                                 {}))
        "a :permanent? that throws is not a way to lose the retry")

# -- :memory -------------------------------------------------------------

(channel/clear!)
(def memory (channel/memory-channel))
(def receipt ((memory :deliver) (note)))
(assert (= :memory (receipt :channel)))
(assert (= "ntf_1" (receipt :id)) "a receipt carries the notification's id, not one of its own")
(assert (= 1 (length channel/outbox)))

(set channel/keep-count 3)
(repeat 5 ((memory :deliver) (note)))
(assert (= 3 (length channel/outbox))
        "the outbox is bounded — a dev server that runs for a week must not grow one notification at a time")
(set channel/keep-count channel/default-keep)
(channel/clear!)
(assert (empty? channel/outbox))

# -- :log ----------------------------------------------------------------

(def logged (((channel/log-channel) :deliver) (note)))
(assert (= :log (logged :channel)))
(assert (= "ntf_1" (logged :id)))
