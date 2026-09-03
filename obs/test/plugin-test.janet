# The void/obs plugin: it composes on core alone, it owns the two
# points reserved for it, its config fails fast, and
# what a started process actually holds.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/obs :as obs)
(import void/obs/metrics :as metrics)
(import void/obs/trace :as trace)
(import void/obs/runtime :as runtime)

(log/set-level! "void.obs" :error)

(def plugins ["void/obs/init"])

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own — no void/http anywhere in it")
(assert (index-of :obs/registry (report :components)))
(assert (index-of :obs/tracer (report :components)))
(assert (get-in report [:extensions :void.obs/exporter])
        "it owns the exporter point void/obs-otlp contributes to — and owns it whether or not that plugin is composed")
(assert (get-in report [:extensions :void.obs/instrument]))
(assert (pos? (get-in report [:extensions :void.obs/instrument :contributions]))
        "and ships the instrumentations of the wave-2 data plugins itself")

(each [slice reason]
  [[{:obs {:max-label-sets 0}} "a cardinality cap of zero"]
   [{:obs {:runtime {:interval 0}}} "a sampler that never samples"]
   [{:obs {:trace {:sample-rate 2}}} "a sampling rate above 1"]
   [{:obs {:trace {:exporter :otlp}}} "an exporter that is a plugin (void/obs-otlp), not a value of this enum"]
   [{:obs {:log {:sample -1}}} "a negative log sampling rate"]
   [{:obs {:log {:file {}}}} "a file sink with no path"]
   [{:obs {:enabled "yes"}} "a flag that is not a boolean"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test
                                      :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- defaults ------------------------------------------------------------

(assert (= 1 (get-in obs/defaults [:trace :sample-rate]))
        "every request gets a span by default — a span is what puts the trace id in the log line, and correlation that works one request in ten is worse than none")
(assert (= 1 (get-in obs/defaults [:log :sample]))
        "and nothing samples the log until a service has measured its volume")
(assert (nil? (get-in obs/defaults [:trace :exporter]))
        "the exporter default is profile-dependent, so it is not a value in the table")

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:obs {:max-label-sets 250
                                                 :runtime {:interval 0.01}}})}))

(assert (get-in boot [:system :instances :obs/registry]))
(assert (runtime/sampling?) "the loop-lag sampler is running")
(ev/sleep 0.05)
(assert (pos? (runtime/state :samples)) "and sampling")

(assert trace/enabled "tracing is on")
(assert (= 1 trace/default-sample-rate))
(assert (empty? trace/exporters)
        "with no exporter outside :dev — a production process should not pay for a log line per span nobody reads")

(def s (obs/status))
(assert (= 250 (s :max-label-sets)) "the cardinality cap comes from config")
(assert (pos? (s :metrics)))
(assert (s :sampling))
(assert (get-in s [:trace :enabled]))
(assert (= [:void.http/client] (tuple ;(s :instrumented)))
        "nothing to instrument in a composition that is only obs — except the HTTP client, which is a module rather than a component and reports no series until this process has actually called out")

(def text (obs/render))
(assert (string/find "# TYPE void_obs_loop_lag_seconds histogram" text)
        "and the exposition is one call away from the REPL")

(def cli (plugin/extension boot :void.core/cli))
(assert (= 2 (length cli)) "void obs status and void obs metrics")
(assert (index-of :obs/metrics (map |($ :name) cli)))

(def sinks (plugin/extension boot :void.core/log-sink))
(assert (= 2 (length sinks)) "the counting sink and the (inert) file sink")

(def gated
  (plugin/start! {:plugins plugins :profile :test
                  :config (config {:obs {:runtime {:enabled false}
                                         :log {:sample 0.5}}})}))
(def sinks-while-gated (length (log/sinks)))
(plugin/shutdown! gated)
(assert (> (length (log/sinks)) sinks-while-gated)
        "the sampling gate comes back off at :after-stop — the logger outlives the system it was configured for, and the next boot in this process must not log through a gate nobody asked for")

(plugin/shutdown! boot)
(assert (not (runtime/sampling?)) "shutdown stops the sampler")
(assert (not trace/enabled))

# -- turned off ----------------------------------------------------------

(def off (plugin/start! {:plugins plugins :profile :test
                         :config (config {:obs {:enabled false}})}))
(assert (not (runtime/sampling?)) "[:obs :enabled] false starts no sampler")
(assert (not trace/enabled) "and creates no spans")
(plugin/shutdown! off)

# -- the dev exporter ----------------------------------------------------

(def dev (plugin/start! {:plugins plugins :profile :dev
                         :config (config {:obs {:runtime {:enabled false}}})}))
(assert (deep= @[:obs/log] (map |($ :name) trace/exporters))
        "in :dev a span goes to the log — how tracing is visible before there is a collector")
(assert (not (runtime/sampling?)) "and [:obs :runtime :enabled] false leaves the loop unsampled")
(plugin/shutdown! dev)

(print "plugin-test ok")
