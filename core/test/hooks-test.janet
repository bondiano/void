(import ../void/core/hooks :as hooks)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- hook registry: validation -------------------------------------------

(def reg (hooks/registry))

(expect-error "non-keyword hook" "keyword"
  |(hooks/add! reg "before-start" (fn [_] nil)))
(expect-error "non-function handler" "function"
  |(hooks/add! reg :before-start 42))
(expect-error "unknown option" "unknown option"
  |(hooks/add! reg :before-start (fn [_] nil) :prio 1))
(expect-error "bad phase" ":phase"
  |(hooks/add! reg :before-start (fn [_] nil) :phase 1.5))
(expect-error "odd options" "key-value"
  |(hooks/add! reg :before-start (fn [_] nil) :phase))

# -- ordering: phase, then name; args reach handlers ---------------------

(def log @[])
(hooks/add! reg :boot (fn [x] (array/push log [:b x])) :phase 2000 :name :b)
(hooks/add! reg :boot (fn [x] (array/push log [:a x])) :phase 2000 :name :a)
(hooks/add! reg :boot (fn [x] (array/push log [:late x])) :phase 3000 :name :late)
(hooks/add! reg :boot (fn [x] (array/push log [:early x])) :phase 10 :name :early)

(assert (= 4 (hooks/run! reg :boot :ctx)) "run! returns the handler count")
(assert (= (freeze log)
           [[:early :ctx] [:a :ctx] [:b :ctx] [:late :ctx]])
        "handlers run by :phase, ties broken by :name, args passed through")

(assert (zero? (hooks/run! reg :never-registered)) "unknown hook is a no-op")

# re-adding the same name replaces the handler
(hooks/add! reg :boot (fn [x] (array/push log [:early2 x])) :phase 10 :name :early)
(array/clear log)
(hooks/run! reg :boot 1)
(assert (= [:early2 1] (first log)) "same :name replaces the handler")

# remove!
(assert (hooks/remove! reg :boot :late))
(assert (nil? (hooks/remove! reg :boot :late)) "second remove returns nil")
(assert (= 3 (length (hooks/handlers reg :boot))))
(assert (= 3 (length (hooks/handlers reg))) "handlers without hook lists everything")

# -- error propagation ---------------------------------------------------

(def ereg (hooks/registry))
(def eorder @[])
(hooks/add! ereg :h (fn [_] (array/push eorder :first)) :phase 1 :name :ok)
(hooks/add! ereg :h (fn [_] (error "boom")) :phase 2 :name :bad :plugin :test/p)
(hooks/add! ereg :h (fn [_] (array/push eorder :third)) :phase 3 :name :after)

(def msg (expect-error "run! fail-fast" "boom" |(hooks/run! ereg :h nil)))
(assert (string/find ":bad" msg) "error names the handler")
(assert (string/find "test/p" msg) "error names the plugin")
(assert (= [:first] (freeze eorder)) "run! stops at the failing handler")

(array/clear eorder)
(def errs (hooks/run-protected! ereg :h nil))
(assert (= 1 (length errs)))
(assert (string/find "boom" (errs 0)))
(assert (= [:first :third] (freeze eorder))
        "run-protected! keeps going past a failing handler")

# -- bus: delivery, wildcard, ordering per subscriber --------------------

(def b (hooks/bus))
(def got @[])
(hooks/subscribe! b :user/created |(array/push got [:direct ($ :payload)]) {:name :direct})
(hooks/subscribe! b :* |(array/push got [:audit ($ :topic)]) {:name :audit})

(assert (= 2 (hooks/publish! b :user/created {:id 1}))
        "publish! counts topic + wildcard subscribers")
(assert (= 1 (hooks/publish! b :order/paid {:id 2}))
        "unrelated topic reaches only the wildcard")
(ev/sleep 0.05)
(assert (deep= got @[[:direct {:id 1}] [:audit :user/created] [:audit :order/paid]])
        "handlers received their events in publish order")

# a failing handler does not kill the subscriber fiber
(def bus-errors @[])
(def b2 (hooks/bus {:on-error (fn [sub event err] (array/push bus-errors [(sub :name) err]))}))
(def seen @[])
(hooks/subscribe! b2 :t
                  (fn [e]
                    (when (= :boom (e :payload)) (error "handler boom"))
                    (array/push seen (e :payload)))
                  {:name :fragile})
(hooks/publish! b2 :t :boom)
(hooks/publish! b2 :t :fine)
(ev/sleep 0.05)
(assert (= [:fine] (freeze seen)) "subscriber survives its own error")
(assert (deep= bus-errors @[[:fragile "handler boom"]]) ":on-error observes the failure")

# unsubscribe by subscription value and by name
(def tmp-sub (hooks/subscribe! b2 :t (fn [_] nil) {:name :tmp}))
(assert (hooks/unsubscribe! b2 tmp-sub))
(assert (nil? (hooks/unsubscribe! b2 :t :tmp)) "already removed")
(hooks/publish! b2 :t :fine2)
(ev/sleep 0.05)
(assert (= [:fine :fine2] (freeze seen)))

# -- bus: validation and close -------------------------------------------

(expect-error "bad topic" "keyword" |(hooks/publish! b2 "t" 1))
(expect-error "bad handler" "function" |(hooks/subscribe! b2 :t 42))
(expect-error "bad bus option" "unknown option" |(hooks/bus {:bufer 1}))

(hooks/close! b)
(hooks/close! b2)
(expect-error "publish after close" "closed" |(hooks/publish! b2 :t 1))
(expect-error "subscribe after close" "closed" |(hooks/subscribe! b2 :t (fn [_] nil)))

(print "hooks-test: all assertions passed")
