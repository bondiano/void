(import ../test-support/paths)
(import void/core/log :as log)
(import void/bus/backend :as backend)
(import void/bus/memory :as memory)

(log/set-level! "void.bus.memory" :fatal)

(defn- env [topic payload]
  @{:id (string "id-" payload) :topic topic :body payload :meta-body "{}"
    :meta @{}})

(defn- settle [] (ev/sleep 0.02))

# -- one group, in order -------------------------------------------------

(def m (memory/make {:buffer 8 :keep 3}))
(def b (backend/normalize (memory/store m)))

(assert (= :at-most-once (get-in b [:guarantees :delivery]))
        "the in-process backend promises the least, out loud")
(assert (not (backend/durable? b)) "and does not pretend to be durable")
(assert (= :per-group (get-in b [:guarantees :ordering])))
(assert (not (b :encoded?)) "it keeps values, so :raw is usable with it")

(def seen @[])
(def sub ((b :consume!) {:group :one} (fn [e] (array/push seen (e :body)))))
(each i [1 2 3] ((b :publish!) (env :t/x i)))
(settle)
(assert (deep= @[1 2 3] seen) "one reader, so the group's order is the publish order")

# -- fan-out is per group ------------------------------------------------

(def other @[])
(def sub2 ((b :consume!) {:group :two} (fn [e] (array/push other (e :body)))))
((b :publish!) (env :t/x 4))
(settle)
(assert (deep= @[1 2 3 4] seen))
(assert (deep= @[4] other)
        "a second group sees everything published after it joined — and nothing before")

(def [ok err] (protect ((b :consume!) {:group :two} (fn [_]))))
(assert (not ok) "a group already consuming in this process is a mistake, not a second reader")

# -- a group only wants what it subscribed to ----------------------------

(def filtered @[])
(def sub3 ((b :consume!) {:group :three
                          :match? (fn [t] (= t :wanted/one))}
           (fn [e] (array/push filtered (e :topic)))))
((b :publish!) (env :wanted/one 5))
((b :publish!) (env :unwanted/two 6))
(settle)
(assert (deep= @[:wanted/one] filtered)
        "the topics hint keeps a group's buffer for the messages it asked for")

# -- a message nobody is consuming is gone -------------------------------

((b :stop!) sub)
((b :stop!) sub2)
((b :stop!) sub3)
((b :publish!) (env :t/x 99))
(settle)
(assert (not (index-of 99 seen)) "at-most-once: no log to catch up with")
(assert (pos? (get ((b :stats)) :dropped))
        "and the count of what nobody took is visible")

# -- a handler that throws does not take the consumer with it ------------

(def after @[])
(var boom true)
(def sub4
  ((b :consume!) {:group :four}
   (fn [e]
     (when boom (set boom false) (error "no"))
     (array/push after (e :body)))))
((b :publish!) (env :t/x 10))
((b :publish!) (env :t/x 11))
(settle)
(assert (deep= @[11] after)
        "the failed message is dropped and the next one is still delivered")
(assert (= 1 (get ((b :stats)) :failed)))
((b :stop!) sub4)

# -- the history ring is inspection, never replay ------------------------

(def hist (memory/recent m))
(assert (= 3 (length hist)) "the ring keeps [:bus :memory :keep] envelopes")
(assert (= 11 (get (last (memory/recent m)) :body))
        "and the newest is last")

(def fresh @[])
(def sub5 ((b :consume!) {:group :five} (fn [e] (array/push fresh (e :body)))))
(settle)
(assert (empty? fresh) "a late subscriber is not handed the history")
((b :stop!) sub5)

# -- stopping twice, and closing -----------------------------------------

((b :stop!) sub5)
(assert true "stopping a stopped consumer is not an error")
((b :close))
(assert (empty? (memory/recent m)) "close drops the ring with everything else")

# -- the factory ---------------------------------------------------------

(var captured nil)
(def f (memory/factory (fn [state] (set captured state))))
(assert (= :memory (f :name)))
(def made (backend/normalize ((f :make) {:memory {:buffer 4 :keep 2}})))
(assert (= 2 (captured :keep)) "the factory hands its state back for `bus/recent`")
((made :close))

(print "void/bus/memory tests OK")
