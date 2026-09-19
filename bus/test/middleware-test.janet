(import ../test-support/paths)
(import void/core/log :as log)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/memory :as memory)
(import void/bus/message :as message)
(import void/bus/middleware :as mw)
(import void/bus/state :as state)

(log/set-level! "void" :fatal)

(defn- msg
  {:params [(or :nil {:keyword :any})] :ret @{:id :string :topic :keyword :payload :any
                                               :meta :table & r}}
  "A ready-made message, with `extra` merged over it."
  [&opt extra]
  (merge (message/make :t/x {:n 1}) (or extra {})))

(defn- run
  {:params [{:wrap (fn [:any :any] :any) & r} (fn [:any] :any) :any (or :nil {:keyword :any})]
   :ret :any}
  "Run one middleware around `handler`, on `in` (default a fresh
  message) with `opts` (default none)."
  [m handler &opt in opts]
  (((m :wrap) handler (or opts {})) (or in (msg))))

(defn- fails-with
  {:params [:string (fn [] :any)] :ret :nil :throws [:string]}
  "Assert that `thunk` raises an error whose text contains `needle`."
  [needle thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string "expected an error mentioning " needle))
  (assert (string/find needle (string err))
          (string/format "expected %q in %q" needle (string err)))
  nil)

(defn- names
  {:params [[{:name :keyword & r}]] :ret @[:keyword]}
  "The names of a chain, in order."
  [chain]
  (map |($ :name) chain))

(defn- noop-wrap
  {:params [(fn [:any] :any) :any] :ret (fn [:any] :any)}
  "A :wrap that wraps nothing."
  [h _]
  h)

# -- the anchors ---------------------------------------------------------

(assert (deep= [:void.bus/guarded :void.bus/observed :void.bus/admitted :void.bus/validated]
               mw/anchors)
        "the bus chain has four named places, outermost first")

# -- the built-in spine --------------------------------------------------

(def tracer
  {:with-span (fn [_ _ f] (f)) :parse (fn [_] nil) :traceparent (fn [] nil)})

(defn- broker
  {:params [{:keyword :any} (or :nil [:any])] :ret @{:chain [:any] & r}}
  "A broker over a fresh in-process backend, with `cfg` and the
  contributions `contribs`."
  [cfg &opt contribs]
  (state/make (backend/normalize (memory/store (memory/make {})))
              (codec/normalize codec/jdn)
              (merge {:group :default} cfg)
              contribs
              (get cfg :tracer)))

(def everything
  {:retry {:enabled true} :throttle {:max 100} :tracer tracer})

(assert (deep= @[:bus/panic-guard :bus/correlation :bus/tracing :bus/poison
                 :bus/retry :bus/dedup :bus/throttle :bus/validate]
               (names ((broker everything) :chain)))
        "panic-guard < correlation < tracing < poison < retry < dedup < throttle < validate")

(assert (deep= @[:bus/panic-guard :bus/correlation :bus/validate]
               (names ((broker {:retry {:enabled false} :dedup {:enabled false}
                                :poison {:enabled false}}) :chain)))
        "a built-in the slice turns off is not in the chain, and its neighbours close up")

(def inner (mw/normalize {:name :app/inner :after :void.bus/validated :wrap noop-wrap}))
(def early (mw/normalize {:name :app/early :before :void.bus/observed :wrap noop-wrap}))
(def mixed (names ((broker everything [inner early]) :chain)))
(assert (deep= @[:bus/panic-guard :app/early :bus/correlation :bus/tracing :bus/poison
                 :bus/retry :bus/dedup :bus/throttle :bus/validate :app/inner]
               mixed)
        "after validated sits inside validate; before observed sits inside the panic guard")

(def [broke-ok broke-err]
  (protect (broker {} [(mw/normalize {:name :app/lost :after :bus/nope :wrap noop-wrap})])))
(assert (not broke-ok) "an edge to a name nothing has fails the broker")
(assert (string/find ":bus/nope" (string broke-err)))

# -- order: the first in order is outermost ------------------------------

(def trace @[])
(defn- marker
  {:params [:keyword {:keyword :any}] :ret BusMiddleware}
  "A middleware placed by `edges` that records its own name entering
  and leaving, in `trace` — what asserts the chain's order."
  [name edges]
  (mw/normalize
    (merge edges
           {:name name
            :wrap (fn [handler _]
                    (fn [m] (array/push trace [name :in]) (def r (handler m))
                      (array/push trace [name :out]) r))})))

(def ordered
  (mw/order [(marker :inner {:after :void.bus/validated})
             (marker :outer {:before :void.bus/guarded})]))
(assert (deep= @[:outer :inner] (names ordered))
        "the anchors are not in the order `order` answers")
(def chain (mw/chain ordered (fn [_] (array/push trace [:handler :run]) :done)))
(assert (= :done (chain (msg))))
(assert (deep= @[[:outer :in] [:inner :in] [:handler :run] [:inner :out] [:outer :out]]
               trace)
        "the first in order wraps everything after it")

(fails-with "is a cycle"
  |(mw/order [(mw/normalize {:name :a :after [:void.bus/guarded :b] :wrap noop-wrap})
              (mw/normalize {:name :b :after :a :wrap noop-wrap})]))
(fails-with "does not require"
  |(mw/order [(merge (mw/normalize {:name :a :after :void.bus/guarded :wrap noop-wrap})
                     {:plugin :app/one})
              (merge (mw/normalize {:name :b :after :a :wrap noop-wrap})
                     {:plugin :app/two})]
             {:requires {:app/one {} :app/two {}}}))

# -- selection -----------------------------------------------------------

(def named (mw/normalize {:name :opt-in :named true :after :void.bus/validated
                          :wrap noop-wrap}))
(def global (mw/normalize {:name :always :after :void.bus/validated :wrap noop-wrap}))
(def conditional
  (mw/normalize {:name :only-audited :after :void.bus/validated
                 :when (fn [opts] (= :audit (get opts :group)))
                 :wrap noop-wrap}))

(def all-mw (mw/order [named global conditional]))
(assert (deep= @[:always] (names (mw/select all-mw {:topic :a/b})))
        "a :named middleware is not in a chain that did not ask for it")
(assert (deep= @[:always :opt-in]
               (names (mw/select all-mw {:topic :a/b :middleware [:opt-in]})))
        "and is when it did")
(assert (deep= @[:always :only-audited]
               (names (mw/select all-mw {:topic :a/b :group :audit})))
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

(var tries 0)
(def [ok2 _]
  (protect (run (mw/retry {:attempts 2 :base 0.001 :jitter 0})
                (fn [_] (++ tries) (error "no")))))
(assert (not ok2) "out of attempts, the error goes on to the backend")
(assert (= 2 tries) "and it was tried exactly :attempts times")

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

(assert (not (first (protect (mw/normalize {:name :x :after :void.bus/validated}))))
        "a middleware without a :wrap wraps nothing")
(assert (not (first (protect (mw/normalize {:after :void.bus/validated :wrap noop-wrap}))))
        "and one without a name cannot be selected by one")
(fails-with "is not placed" |(mw/normalize {:name :x :wrap noop-wrap}))
(fails-with "removed in ADR-0051"
  |(mw/normalize {:name :x :wrap noop-wrap :phase 7000}))
(fails-with "removed in ADR-0051"
  |(mw/placement-check [{:name :x :wrap noop-wrap :phase 7000}]))
(assert (nil? (mw/placement-check [{:name :x :after :bus/retry :wrap noop-wrap}]))
        "the boot checks an edge to a built-in against the whole spine")
(fails-with "is unknown" |(mw/placement-check [{:name :x :after :bus/retyr :wrap noop-wrap}]))

(print "void/bus/middleware tests OK")
