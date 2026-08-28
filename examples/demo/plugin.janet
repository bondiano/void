### demo/greeter — the wave-0 toy plugin.
### The whole plugin cycle in one file: a config slice with schema and
### defaults, a stateful component providing the :demo/greeter
### interface, and contributions to the core cli/health extension
### points. An application enables it with one :plugins entry —
### deleting that entry removes every trace.

(import void/core/plugin :as plugin)
(import void/core/system :as system)

(defn greet
  "Greet `who` through a started :demo/greeter instance."
  [inst who]
  (put inst :greeted (inc (inst :greeted)))
  (string (inst :greeting) ", " who "!"))

(def greeter-service
  (system/component :demo/greeter-service
    :doc "Holds the configured greeting and counts greetings served."
    :provides [:demo/greeter]
    :config {:key :greeter}
    :start (fn [deps cfg] @{:greeting (cfg :greeting) :greeted 0})
    :stop (fn [inst] (put inst :greeting nil))
    :health (fn [inst] {:status (if (inst :greeting) :up :down)
                        :greeted (inst :greeted)})))

(plugin/contribute! :void.core/interface
  {:name :demo/greeter :doc "Greeting service: (greet inst who)"})

(plugin/contribute! :void.core/cli
  {:name :demo/greet
   :doc "Print a greeting for each NAME argument"
   :needs [:demo/greeter-service]
   :fn (fn [inst & names] (each n names (print (greet inst n))))})

(plugin/contribute! :void.core/health
  {:name :demo/greeter-check
   :fn (fn [] {:status :up})})

(plugin/defplugin demo/greeter
  :doc "Toy demo plugin: a configurable greeting behind the :demo/greeter interface."
  :version "0.1.0"
  :requires {:void/core ">=0.0.1"}
  :config-key :greeter
  :config-schema {:greeting :string}
  :config-defaults {:greeting "hello"}
  :components [greeter-service])
