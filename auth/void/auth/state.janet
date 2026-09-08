### void/auth/state — what the running plugin resolved.
###
### The stores an application composed, the strategies it registered
### and the settings behind them, in one place that both plugins of
### this package (`void/auth` and `void/auth-http`) and any handler can
### reach without threading a value through every call. The same shape
### `void/cache/state` and `void/pressure/state` have, for the same
### reason: a request handler asking "who is this?" should not have to
### have been handed the system map.
###
### A dyn overrides it, so a test stands a different set of stores in
### front of the same code without booting anything.

(import void/core/system :as system)

(def auth
  ``What the :auth/registry component resolved: the stores, the
  strategies and the settings. The `:void.auth/state` dyn overrides it
  for a scope — the test seam that stands a different set of stores in
  front of the same code without booting anything.``
  (system/ambient :void.auth/state :of "the auth registry"
                  :from :void/auth :component :auth/registry))

(def auth-dyn
  "Dyn that overrides the resolved auth value — the test seam."
  (auth :dyn))

(defn active
  "The resolved auth value: the dyn override, or what the component
  put there."
  []
  (system/current auth))

(defn- part [key what]
  (def a (active))
  (unless a
    (errorf "void/auth is not started — %s is unavailable (add :void/auth to :plugins)" what))
  (or (get a key)
      (errorf "this composition has no %s" what)))

(defn users "The active user store." [] (part :users "user store"))
(defn tokens "The active API-token store." [] (part :tokens "token store"))
(defn challenges "The active challenge store." [] (part :challenges "challenge store"))

(defn settings
  "The [:auth] slice as the component resolved it."
  []
  (get (active) :settings {}))

(defn make
  "An auth value without a bootstrap — what the component builds and
  what a test binds to `auth-dyn`."
  [&opt parts]
  (merge @{:users nil :tokens nil :challenges nil :settings {}} (or parts {})))
