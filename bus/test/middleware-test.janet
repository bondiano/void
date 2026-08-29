(import ../test-support/paths)
(import void/core/log :as log)
(import void/bus/message :as message)
(import void/bus/middleware :as mw)

(log/set-level! "void" :fatal)

(defn- msg [&opt extra]
  (merge (message/make :t/x {:n 1}) (or extra {})))

(defn- run [m handler &opt in opts]
  (((m :wrap) handler (or opts {})) (or in (msg))))

# -- the phase scale is void/http's ---------------------------------------

(assert (= 0 (mw/phases :panic-guard)))
(assert (= 1000 (mw/phases :observability)))
(assert (= 6000 (mw/phases :validation)))
(assert (= 7000 (mw/phases :business)))
(assert (= 9000 (mw/phases :response))
        "the constants a bus shares with a request keep their numbers")

# -- order: lowest phase outermost ---------------------------------------

(def trace @[])
(defn- marker [name phase]
  (mw/normalize
    {:name name :phase phase
     :wrap (fn [handler _]
             (fn [m] (array/push trace [name :in]) (def r (handler m))
               (array/push trace [name :out]) r))}))

(def chain
  (mw/chain (mw/sort-contributions [(marker :outer 100) (marker :inner 8000)])
            (fn [_] (array/push trace [:handler :run]) :done)))
(assert (= :done (chain (msg))))
(assert (deep= @[[:outer :in] [:inner :in] [:handler :run] [:inner :out] [:outer :out]]
               trace)
        "the lowest phase wraps everything below it")

# -- selection -----------------------------------------------------------

(def named (mw/normalize {:name :opt-in :named true :wrap (fn [h _] h)}))
(def global (mw/normalize {:name :always :wrap (fn [h _] h)}))
(def conditional
  (mw/normalize {:name :only-audited
                 :when (fn [opts] (= :audit (get opts :group)))
                 :wrap (fn [h _] h)}))

(def all [named global conditional])
(assert (deep= @[:always] (map |($ :name) (mw/select all {:topic :a/b})))
        "a :named middleware is not in a chain that did not ask for it")
(assert (deep= @[:always :opt-in]
               (map |($ :name) (mw/select all {:topic :a/b :middleware [:opt-in]})))
        "and is when it did")
(assert (deep= @[:always :only-audited]
               (map |($ :name) (mw/select all {:topic :a/b :group :audit})))
        "a :when predicate is evaluated once, when the chain is built")

# -- panic-guard re-raises, because a nack is the backend's decision -----

(def [ok err] (protect (run (mw/panic-guard) (fn [_] (error "nope")))))
(assert (not ok) "the guard logs and re-raises")
(assert (string/find "nope" (string err)))

# -- correlation binds the fiber -----------------------------------------

(def parent (message/make :a/b {} {:correlation-id "corr-9"}))
(def child
  (run (mw/correlation)
       (fn [_] (message/make :c/d {}))
       parent))
(assert (= "corr-9" (message/correlation-id child))
        "a message published while handling one inherits the correlation")
(assert (= (parent :id) (get-in child [:meta :causation-id]))
        "and names the message that caused it")
(assert (nil? (dyn message/correlation-dyn))
        "the binding does not outlive the delivery")

# -- retry ---------------------------------------------------------------

(var attempts 0)
(def out
  (run (mw/retry {:attempts 3 :base 0.001 :jitter 0})
       (fn [_] (++ attempts) (if (< attempts 3) (error "again") :finally))))
(assert (= :finally out))
(assert (= 3 attempts) "the last attempt is the one that succeeded")

(var forever 0)
(def [ok2 _]
  (protect (run (mw/retry {:attempts 2 :base 0.001 :jitter 0})
                (fn [_] (++ forever) (error "no")))))
(assert (not ok2) "out of attempts, the error goes on to the backend")
(assert (= 2 forever) "and it was tried exactly :attempts times")

# -- dedup ---------------------------------------------------------------

(var runs 0)
(def deduped ((( mw/dedup {:window 60}) :wrap) (fn [_] (++ runs)) {}))
(def twice (msg))
(deduped twice)
(deduped twice)
(assert (= 1 runs) "the same message id twice is one delivery")
(deduped (msg))
(assert (= 2 runs) "a different message still gets through")

# -- poison --------------------------------------------------------------

(def poisoned @[])
(def publish (fn [topic payload opts] (array/push poisoned [topic payload])))
(def guard ((( mw/poison {:max-attempts 3 :topic :bus/poison} publish) :wrap)
            (fn [_] (error "cannot handle this")) {}))

(def [ok3 _] (protect (guard (message/with-meta (msg) {:redelivery 0}))))
(assert (not ok3) "under the limit the message is nacked, so it comes back")
(assert (empty? poisoned))

(def [ok4 _] (protect (guard (message/with-meta (msg) {:redelivery 1}))))
(assert (not ok4) "still under")

(def r5 (guard (message/with-meta (msg) {:redelivery 2})))
(assert (nil? r5)
        "at the limit the message is acked — an ordered group must not stop on it")
(assert (= 1 (length poisoned)))
(def [topic payload] (first poisoned))
(assert (= :bus/poison topic))
(assert (string/find "cannot handle this" (payload :error))
        "and what could not be handled travels with it")
(assert (= 2 (payload :redelivery)))

# -- throttle paces rather than drops ------------------------------------

(def paced ((( mw/throttle {:max 2 :window 0.2}) :wrap) (fn [_] :ok) {}))
(def t0 (os/clock :monotonic))
(each _ [1 2 3] (paced (msg)))
(assert (> (- (os/clock :monotonic) t0) 0.01)
        "the third message waited rather than being refused")

# -- validation ----------------------------------------------------------

(def Payload {:id :int :name :string})
(def validated
  (fn [payload]
    (run (mw/validate) (fn [m] (m :payload))
         (merge (msg) {:payload payload})
         {:name :h :schema Payload})))

(assert (deep= {:id 42 :name "a"} (validated {:id 42 :name "a"})))
(assert (deep= {:id 42 :name "a"} (validated {:id "42" :name "a"}))
        "coercion is on: the codec that carried this was probably JSON")

(def [ok6 err6] (protect (validated {:id "not a number" :name "a"})))
(assert (not ok6) "a payload that does not match nacks like any other failure")
(assert (string/find "schema" (string err6)))

(assert (not (((mw/validate) :when) {:topic :a/b}))
        "a handler that declared no schema does not get the frame")
(assert (((mw/validate) :when) {:topic :a/b :schema Payload}))

# -- contributions are validated where they are made ---------------------

(assert (not (first (protect (mw/normalize {:name :x}))))
        "a middleware without a :wrap wraps nothing")
(assert (not (first (protect (mw/normalize {:wrap (fn [h _] h)}))))
        "and one without a name cannot be selected by one")
(assert (not (first (protect (mw/normalize {:name :x :wrap (fn [h _] h) :phase :late}))))
        "a phase is a number on a scale, not a word")

(print "void/bus/middleware tests OK")
