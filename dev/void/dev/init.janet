### void/dev — the canonical dev-mode plugin.
###
### A plugin like any other — it proves the Plugin API on itself:
### config slice under :dev with schema + defaults, two stateful
### components (:dev/netrepl, :dev/watcher) and a contribution of the
### :generator schema projection. Include it in :plugins for the dev
### profile; deleting it from the list leaves no trace (wave-0 exit
### criterion 2).

(import void/core/plugin :as plugin)
(import void/core/deploy :as deploy)
(import void/core/log :as log)
(import ./netrepl :as netrepl)
(import ./watch :as watch)
(import ./generate :as generate)

(def Config
  "Schema of the :dev config slice."
  {:netrepl [:optional {:enabled [:optional :boolean]
                        :unix [:optional :string]
                        :host [:optional :string]
                        :port [:optional :int]
                        :allow-remote [:optional :boolean]}]
   :watch [:optional {:enabled [:optional :boolean]
                      :paths [:optional [:vector :string]]
                      :interval [:optional [:number {:min 0.01}]]
                      :exclude [:optional [:vector :string]]}]})

# -- the banner ----------------------------------------------------------
#
# The one thing a dev process prints on its own. It exists for a single
# sentence — the shape this composition is deployed in and which of its
# stores would not survive a second replica — because that is the question
# `[:deploy :shape]` answers at start in :prod and nobody thinks to ask in
# :dev, where the default is :single and the check is inert. Reading it
# here is cheaper than reading it from a failed deploy.

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   # after everything, including the plugins that resolve a store in an
   # :after-start hook of their own
   :phase 9000
   :name :dev/banner
   :doc "Print the profile, the deployment shape and the composition's stores"
   :fn (fn banner [boot]
         (print)
         (printf "void %q — %d plugins, %d components"
                 (boot :profile)
                 (length (boot :active))
                 (length (get-in boot [:system :order] [])))
         (each l (deploy/report boot) (print l))
         (print))})

# -- where the application is --------------------------------------------
#
# void/http fires :void.http/listening with the bound server the moment
# the socket is open; this is the one line that answers the first
# question a person at a terminal actually has.

(plugin/contribute! :void.core/hooks
  {:hook :void.http/listening
   :phase 1000
   :name :dev/listening
   :doc "Say where the application is listening"
   :fn (fn listening [boot srv]
         (log/info (string/format "listening on http://%s:%d"
                                  (get srv :host "127.0.0.1")
                                  (get srv :port 0))
                   :ns "void.dev"))})

(plugin/defplugin void/dev
  :doc "Dev experience: in-process netrepl, file watcher with component auto-restart, schema generator."
  :version "0.0.1"
  # a netrepl is an unauthenticated eval in the application's address
  # space: whatever the :plugins list says, this plugin has no business
  # being active in :prod
  :when (fn [_] (not= :prod (dyn :void/profile)))
  :config-key :dev
  :config-schema Config
  :config-defaults {:netrepl {:enabled true :unix netrepl/default-unix-path}
                    :watch {:enabled true :paths ["."] :interval 0.5}}
  :components [netrepl/component watch/component]
  :contributes {:void.core/schema-projection
                [{:name :generator :fn generate/projection}]})
