(import ../void/core/deadline :as deadline)
(import ../void/core/errors :as errors)

(defn expect-error [name pred thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (pred err) (string name ": unexpected error " (string/format "%q" err)))
  err)

# -- run: the three outcomes ---------------------------------------------

(assert (deep= [:ok 42] (deadline/run 1 (fn [] 42))) "returns before the deadline")
(assert (deep= [:ok 42] (deadline/run 1 (fn [] (ev/sleep 0.01) 42)))
        "an ev operation inside the task is fine")
(assert (deep= [:timeout nil] (deadline/run 0.02 (fn [] (ev/sleep 5) :late)))
        "the deadline cancels the task")
(assert (deep= [:error "boom"] (deadline/run 1 (fn [] (error "boom"))))
        "the work's own error comes back as a value")

# an error that merely mentions a deadline is an error — the whole
# cancellation value is matched, never a substring
(assert (deep= [:error "a deadline in the message"]
               (deadline/run 1 (fn [] (error "a deadline in the message")))))

# the error value keeps its shape (an envelope stays an envelope)
(def [outcome env] (deadline/run 1 (fn [] (errors/raise :test/kind "shaped" {:k 1}))))
(assert (= :error outcome))
(assert (= :test/kind (errors/kind env)))
(assert (= 1 (get (errors/data env) :k)))

# -- run: no deadline means no task --------------------------------------

(each seconds [nil 0 -1]
  (def root (fiber/root))
  (assert (deep= [:ok true]
                 (deadline/run seconds (fn [] (= root (fiber/root)))))
          (string/format "seconds=%q: the work runs under the caller's root task" seconds))
  (assert (deep= [:error "inline"] (deadline/run seconds (fn [] (error "inline"))))
          "and its error is still an outcome, not a throw"))

(def root (fiber/root))
(assert (deep= [:ok false] (deadline/run 1 (fn [] (= root (fiber/root)))))
        "with a deadline the work is a child task")

# -- run: the child sees the caller's dyns -------------------------------

(with-dyns [:test/dyn :bound]
  (assert (deep= [:ok :bound] (deadline/run 1 (fn [] (dyn :test/dyn))))
          "a handler under a deadline still finds its request-scoped bindings"))

# -- run: the caller's own fiber survives the timeout --------------------

# the point of the module: the deadline lands on the child and the
# caller goes on — with ev/with-deadline this fiber would be the one
# cancelled
(def survived
  (do
    (deadline/run 0.01 (fn [] (ev/sleep 5)))
    (ev/sleep 0.01)
    :still-here))
(assert (= :still-here survived))

# -- run: a caller that leaves takes the child with it -------------------

(def child-state @{:cancelled false :finished false})
(def sup (ev/chan 1))
(def caller
  (ev/go (fn abandoned-caller []
           (deadline/run 5 (fn []
                             (defer (put child-state :cancelled true)
                               (ev/sleep 5)
                               (put child-state :finished true)))))
         nil sup))
(ev/sleep 0.02)
(ev/cancel caller "request timed out above us")
(ev/take sup)
(ev/sleep 0.02)
(assert (child-state :cancelled) "the parked child was cancelled, not orphaned")
(assert (not (child-state :finished)) "and never ran to its end")

# -- call --------------------------------------------------------------

(assert (= 7 (deadline/call 1 (fn [] 7))))
(assert (= 7 (deadline/call nil (fn [] 7))) "no deadline: the value")
(assert (= :fallback (deadline/call 0.01 (fn [] (ev/sleep 5)) (fn [] :fallback)))
        "on-timeout's value stands in")

(def raised
  (expect-error "call re-raises the work's error as it was"
                |(= "boom" $)
                |(deadline/call 1 (fn [] (error "boom")))))

(def env-raised
  (expect-error "an envelope survives the re-raise"
                |(= :test/kind (errors/kind $))
                |(deadline/call 1 (fn [] (errors/raise :test/kind "shaped")))))

(def default-timeout
  (expect-error "without on-timeout the kernel's own kind is raised"
                |(errors/kind? $ :void/deadline)
                |(deadline/call 0.01 (fn [] (ev/sleep 5)))))
(assert (= 504 (errors/status default-timeout)) "a gateway timeout")
(assert (= 0.01 (get (errors/data default-timeout) :timeout)) "carrying the limit as data")

# on-timeout may raise, and what it raises is what the caller sees
(expect-error "on-timeout's own error"
              |(= :mine (get $ :tag))
              |(deadline/call 0.01 (fn [] (ev/sleep 5)) (fn [] (error {:tag :mine}))))

# a wait on a channel, which is what pools and workers put under a
# deadline: a give in time is the value, none is the fallback
(def ch (ev/chan 1))
(ev/give ch :handed)
(assert (= :handed (deadline/call 1 (fn [] (ev/take ch)) (fn [] nil))))
(assert (nil? (deadline/call 0.01 (fn [] (ev/take ch)) (fn [] nil))))

(print "deadline-test: all assertions passed")
