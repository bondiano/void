# void/core/log — ADR-0018: lazy level macros, per-namespace prefix
# tree, bound context, serializers, redaction, sinks (pretty format
# snapshot + jdn drop policy), and the plugin/start! wiring of
# [:log] config + contributed sinks/serializers.

(import ../void/core/log :as log)
(import ../void/core/plugin :as plugin)
(import ../void/core/schema :as schema)

(defn- capture-sink [buf]
  (fn [rec] (array/push buf (freeze rec))))

# -- levels: prefix tree + lazy args -------------------------------------

(log/configure! {:level :info} :test)
(def recs @[])
(log/set-sinks! [(capture-sink recs)])

(var evaluated false)
(log/debug (do (set evaluated true) "never"))
(assert (not evaluated) "a disabled level does not evaluate its args")

(log/set-level! "my-app" :error)
(log/set-level! "my-app.orders" :debug)
(assert (log/enabled? "my-app.orders" :debug) "longest prefix wins")
(assert (not (log/enabled? "my-app.billing" :warn)) "parent prefix inherited")
(assert (log/enabled? "elsewhere" :info) "root minimum")

(log/info "plain" :n 1)
(assert (= 1 (length recs)))
(def rec (recs 0))
(assert (= :info (rec :level)))
(assert (= "plain" (rec :msg)))
(assert (= 1 (rec :n)))
(assert (number? (rec :ts)))
(assert (string/find "log-test" (rec :ns)) "ns derives from the file")

# -- context -------------------------------------------------------------

(array/clear recs)
(log/with-context {:request-id "r-1"}
  (log/info "in ctx")
  (log/with-context {:user 7}
    (log/info "nested")))
(assert (= "r-1" (get (recs 0) :request-id)))
(assert (= 7 (get (recs 1) :user)))
(assert (= "r-1" (get (recs 1) :request-id)) "contexts nest by merge")

(array/clear recs)
(def carried (log/carrying (fn [] (log/info "from task"))))
(def f (ev/go (fn [] (carried))))
(ev/sleep 0.01)
(assert (= nil (get (recs 0) :request-id)) "wrap-time context was empty")

# -- serializers + redaction ---------------------------------------------

(array/clear recs)
(log/set-serializers! {:req (fn [r] {:path (r :path)})})
(log/set-redact! [[:password]])
(log/info "shaped" :req {:path "/x" :headers {:secret "y"}} :password "hunter2")
(assert (deep= {:path "/x"} (get (recs 0) :req)) "serializer shapes the key")
(assert (= "[redacted]" (get (recs 0) :password)))
(log/error "went wrong" :err "boom")
(assert (= {:msg "boom"} (get (recs 1) :err)) "the :err serializer survives set-serializers!")

# -- pretty format snapshot ----------------------------------------------

(def pretty (log/pretty-sink {:color false}))
(def line @"")
(with-dyns [:err line]
  (pretty {:ts 0 :level :warn :ns "app.web" :msg "slow" :ms 12}))
(assert (peg/match '(* (some (+ :d ":")) " WARN  app.web — slow ms=12" "\n" -1)
                   (string line))
        (string "pretty line format: " line))

# -- jdn sink: async write + drop policy ---------------------------------

(def out @"")
(def jdn (log/jdn-sink {:buffer 2 :stream (file/temp)}))
# a tiny buffer overflows when the writer never yields: emit from a
# tight loop, then let the writer fiber drain
(def before (log/dropped))
(repeat 10 (jdn {:ts 0 :level :info :ns "x" :msg "m"}))
(assert (> (log/dropped) before) "overflow drops instead of blocking")
(log/close!)

# -- plugin/start! wiring ------------------------------------------------

(def sink-recs @[])
(def sink-plugin
  (plugin/manifest 'test/log-sink
    :version "1.0.0"
    :contributes
    {:void.core/log-sink [{:name :test/capture :fn (capture-sink sink-recs)}]
     :void.core/log-serializer [{:key :order :fn (fn [o] (o :id))}]}))

(def boot (plugin/start!
            (plugin/bootstrap {:plugins [sink-plugin]
                               :profile :test
                               :config {:env @{} :cli {:log {:level :debug}}}}
                              true)))
(log/info "through boot" :order {:id 42 :noise true})
(assert (= 1 (length sink-recs)) "contributed sink installed")
(assert (= 42 (get (sink-recs 0) :order)) "contributed serializer applied")
(assert (log/enabled? "anything" :debug) "[:log :level] applied")
(plugin/shutdown! boot)

# invalid [:log] config fails start!, batched through schema
(def [ok err]
  (protect (plugin/start!
             (plugin/bootstrap {:plugins []
                                :profile :test
                                :config {:env @{} :cli {:log {:level :loud}}}}
                               true))))
(assert (not ok))
(assert (string/find "[:log]" err) (string "log config error names the slice: " err))

# restore defaults for whoever runs next in this process
(log/configure! nil :test)
(print "log-test: ok")
