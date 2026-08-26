### void/dev — the canonical dev-mode plugin (SPEC.md §4).
###
### A plugin like any other — it proves the Plugin API on itself:
### config slice under :dev with schema + defaults, two stateful
### components (:dev/netrepl, :dev/watcher) and a contribution of the
### :generator schema projection. Include it in :plugins for the dev
### profile; deleting it from the list leaves no trace (wave-0 exit
### criterion 2).

(import void/core/plugin :as plugin)
(import ./netrepl :as netrepl)
(import ./watch :as watch)
(import ./generate :as generate)

(def Config
  "Schema of the :dev config slice."
  {:netrepl [:optional {:enabled [:optional :boolean]
                        :unix [:optional :string]
                        :host [:optional :string]
                        :port [:optional :int]}]
   :watch [:optional {:enabled [:optional :boolean]
                      :paths [:optional [:vector :string]]
                      :interval [:optional [:number {:min 0.01}]]}]})

(plugin/defplugin void/dev
  :doc "Dev experience: in-process netrepl, file watcher with component auto-restart, schema generator."
  :version "0.0.1"
  :config-key :dev
  :config-schema Config
  :config-defaults {:netrepl {:enabled true :unix netrepl/default-unix-path}
                    :watch {:enabled true :paths ["."] :interval 0.5}}
  :components [netrepl/component watch/component]
  :contributes {:void.core/schema-projection
                [{:name :generator :fn generate/projection}]})
