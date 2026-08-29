(import ../test-support/paths)
(import void/core/log :as log)
(import void/bus :as bus)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/cqrs :as cqrs)
(import void/bus/memory :as memory)
(import void/bus/router :as router)
(import void/bus/state :as state)

(log/set-level! "void" :fatal)

(defn- settle [] (ev/sleep 0.03))

# -- events: a name, a topic and a shape ---------------------------------

(bus/defevent account-debited
  "Money left an account."
  {:topic :account/debited
   :schema {:account :string :amount [:number {:min 0}]}})

(assert (= :account/debited (account-debited :topic)))
(assert (= "Money left an account." (account-debited :doc)))
(assert (deep= @[:account-debited] (cqrs/declared-events)))

(bus/defevent heartbeat {})
(assert (= :heartbeat (get (cqrs/event :heartbeat) :topic))
        "an event's topic defaults to its name")

(assert (not (first (protect (cqrs/define-event! :bad {:topic "account/debited"}))))
        "a topic is a keyword")
(assert (not (first (protect (cqrs/define-event! :bad {:schema [:no-such-type]}))))
        "a schema that cannot be read is a load error, not a surprise on the first message")
(assert (not (first (protect (cqrs/event :never-declared))))
        "an undeclared event cannot be emitted by accident")

# -- emit! validates on the publishing side ------------------------------

(def m (memory/make {}))
(def b (backend/normalize (memory/store m)))
(def br (state/make b (codec/normalize codec/jdn)
                    {:group :default :dedup {:enabled false}
                     :poison {:enabled false} :retry {:enabled false}}))

(def received @[])
(bus/defevent-handler on-debit
  "Note the debit."
  {:event :account-debited}
  [msg]
  (array/push received (msg :payload)))

(def d (router/lookup :on-debit))
(assert (= :account/debited (d :topic))
        "a defevent-handler takes its topic from the declaration")
(assert (get-in d [:opts :schema])
        "and its schema, so the shape is written once")

(with-dyns [state/broker-dyn br]
  (state/start-consumers! br)

  (def sent (cqrs/emit! :account-debited {:account "42" :amount 10}))
  (assert (= :account/debited (sent :topic)))
  (settle)
  (assert (= 1 (length received)))
  (assert (= 10 (get-in received [0 :amount])))

  (def [ok err] (protect (cqrs/emit! :account-debited {:account "42" :amount -1})))
  (assert (not ok) "a payload that does not match is refused where it can still be fixed")
  (assert (string/find "schema" (string err)))

  (def [ok2 _] (protect (cqrs/emit! :account-debited {:amount 10})))
  (assert (not ok2) "and so is one that is missing a field")
  (settle)
  (assert (= 1 (length received)) "neither reached a consumer")

  # coercion at the consumer, because the codec is usually lossy
  (state/publish :account/debited {:account "43" :amount "25"})
  (settle)
  (assert (= 25 (get-in received [1 :amount]))
          "the handler's schema coerces what the codec could not keep")

  # a message that does not match nacks rather than reaching the body
  (state/publish :account/debited {:account "44" :amount "lots"})
  (settle)
  (assert (= 2 (length received)) "the handler never saw it")

  (state/stop-consumers! br))

# -- commands: exactly one handler, and a reply --------------------------

(def debited @[])
(bus/defcommand debit-account
  "Take money off an account."
  {:schema {:account :string :amount [:number {:min 0}]}}
  [cmd]
  (array/push debited cmd)
  {:balance 90})

(assert (deep= @[:debit-account] (cqrs/declared-commands)))
(assert (deep= {:balance 90} (cqrs/send :debit-account {:account "42" :amount "10"}))
        "send returns what the handler returned, over a coerced payload")
(assert (= 10 (get-in debited [0 :amount])))

(def [ok3 err3] (protect (cqrs/send :debit-account {:account "42" :amount -5})))
(assert (not ok3) "the command's schema is checked before its body runs")

(def [ok4 err4] (protect (cqrs/send :credit-account {})))
(assert (not ok4) "a command with no handler here is an error, not a message that goes off to be lost")
(assert (string/find "declared" (string err4)))

(def [ok5 err5]
  (protect (cqrs/define-command! :debit-account {} {:binding 'other :fn (fn [_])})))
(assert (not ok5) "a second handler for one command is refused where it is declared")
(assert (string/find "exactly one" (string err5))
        "and the message says what the rule is")

(cqrs/define-command! :debit-account {}
                      {:binding 'debit-account :fn (fn [_] :reloaded)})
(assert (= :reloaded (cqrs/send :debit-account {}))
        "redefining the same binding is a reload, not a conflict")

# -- calling the body directly skips the layer ---------------------------

(assert (deep= {:balance 90} (debit-account {:account "x" :amount 1}))
        "a command handler is an ordinary function, which is what a unit test wants")

(print "void/bus/cqrs tests OK")
