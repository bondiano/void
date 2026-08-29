(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/test :as test)
(import void/bus :as bus)
(import void/bus/router :as router)
(import void/bus/state :as state)

(log/set-level! "void" :error)

(def plugins ["void/bus/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}} extra)})

(defn- start [&opt extra profile]
  (test/start! {:plugins plugins
                :profile (or profile :test)
                :config (config (or extra {}))}))

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok))
(assert (= 3 (get-in report [:extensions :void.bus/codec :contributions]))
        "the package ships :json, :jdn and :raw")
(assert (= 1 (get-in report [:extensions :void.bus/backend :contributions]))
        "and one backend, the in-process one")
(assert (get-in report [:extensions :void.bus/middleware])
        "the middleware point is declared even with nothing in it")

# -- what the boot refuses ----------------------------------------------

(each [extra reason]
  [[{:bus {:backend :kafka}} "a backend nobody contributed"]
   [{:bus {:codec :protobuf}} "a codec nobody contributed"]]
  (assert (not (first (protect (start extra))))
          (string reason " stops the boot")))

(def [_ err] (protect (start {:bus {:backend :kafka}})))
(assert (string/find "memory" (string err))
        "and the error lists the backends this composition actually has")

# :raw is legal here and nowhere durable: the in-process backend keeps
# values, so a composition that has read void/bus/codec may skip the
# round trip. The refusal is against a backend that stores bytes, and
# it is in test/codec-test.janet
(def rawboot (start {:bus {:codec :raw}}))
(test/stop! rawboot)

# -- a booted bus --------------------------------------------------------

(def handled @[])
(bus/defhandler on-anything {:topic :app/*} [msg]
  (array/push handled (msg :topic)))

(def boot (start {:bus {:group :app}}))

(defer (test/stop! boot)
  (def br state/current-broker)
  (assert br "the :bus/broker component sets the process's broker")
  (assert (= :memory (get-in br [:backend :name])))
  (assert (= :json (get-in br [:codec :name])))
  (assert (= :app (br :group)))

  # the :after-start hook started a consumer for the declared handler
  (assert (deep= @[:app] (sorted (keys (br :consumers))))
          "a process that declared handlers consumes them")

  (bus/publish :app/thing {:n 1})
  (ev/sleep 0.05)
  (assert (deep= @[:app/thing] handled))

  # a topic outside the pattern does not reach it
  (bus/publish :other/thing {})
  (ev/sleep 0.05)
  (assert (= 1 (length handled)))

  # -- what the CLI reads -------------------------------------------------

  (def s (bus/stats))
  (assert (= :memory (get-in s [:backend :name])))
  (assert (not (get-in s [:backend :durable])) "and says it is not durable")
  (assert (= 2 (s :published)))
  (assert (not (s :outbox)) "no outbox without void/bus-db")
  (assert (index-of :on-anything (s :handlers)))

  (assert (pos? (length (bus/recent))) "the in-process history is readable")
  (assert (= :app/thing (get (first (bus/recent)) :topic))
          "and comes back as messages, decoded")

  # -- the guarantees are what the backend declared ----------------------

  (def caps (bus/capabilities))
  (assert (= :at-most-once (caps :delivery)))
  (assert (= :per-group (caps :ordering))))

# -- a process that must not consume -------------------------------------

(def quiet (start {:bus {:consume false}}))
(defer (test/stop! quiet)
  (assert (empty? (get state/current-broker :consumers))
          "[:bus :consume] false leaves the handlers declared and unread")
  (bus/publish :app/thing {:n 2})
  (ev/sleep 0.05)
  (assert (= 1 (length handled))
          "so a web tier that imports the handler modules does not run them"))

# -- a process with no handlers at all -----------------------------------

(each n (router/defined) (router/forget! n))
(def publisher (start {}))
(defer (test/stop! publisher)
  (assert (empty? (get state/current-broker :consumers))
          "a process that declares no handlers starts no consumer, and that is not an error")
  (assert (bus/publish :app/thing {:n 3})
          "and can still publish, which is the ordinary web-tier shape"))

# -- the codec is the same on both sides, in-heap or not -----------------

(def payloads @[])
(router/define! :shape {:topic :shape/one}
                {:fn (fn [m] (array/push payloads (m :payload)))})
(def shaped (start {}))
(defer (test/stop! shaped)
  (bus/publish :shape/one {:id 42 :nested {:ok true}})
  (ev/sleep 0.05)
  (assert (= 42 (get-in payloads [0 "id"]))
          "the in-process backend runs the codec too, so a test is a test of the real shape"))

(print "void/bus plugin tests OK")
