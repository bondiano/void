### void/dash/context — the boot-time settings of the dashboard, in
### one place so that the views, the mount and the handlers can read
### them without importing each other in a circle (the pose of
### void/admin/context).
###
### Assembled once, at :before-start, from the [:dash] config slice and
### the boot value — and then only read. The dashboard keeps no state
### that affects what a page *says*: every page is a projection of the
### boot and of the process, and the three ring buffers it does keep
### are bounded caches of things the process would otherwise forget.

(import void/html/chrome :as chrome)

(var current
  ``The running dash context, set by ./init's :before-start hook:
  :boot :config :prefix :title :open? :gate :allow-actions?
  :started-at :datastar? :tiles :route-meta :htmx-src :htmx-integrity
  :assets.``
  nil)

(defn context
  {:params [] :ret @{:keyword :any} :throws [:string]}
  "The dash context, or a refusal naming why it is not there."
  []
  (or current
      (error "void/dash is not booted — plugin/start! builds the dash context at :before-start")))

(defn setting
  {:params [:keyword :any?] :ret :any :throws [:string]}
  "One key of the context."
  [k &opt dflt]
  (get (context) k dflt))

(defn boot
  {:params [] :ret :any :throws [:string]}
  "The boot value the dashboard projects."
  []
  (setting :boot))

(defn prefix
  {:params [] :ret :string :throws [:string]}
  "Where the dashboard is mounted ([:dash :prefix], default \"/dash\")."
  []
  (setting :prefix "/dash"))

(defn at
  {:params [:string (or {:string :any} :nil)] :ret :string :throws [:string]}
  ``A URL under the dash prefix: (at "/routes"), (at "/why" {"key"
  "http/server"}) — chrome/url-under over [:dash :prefix].``
  [path &opt query]
  (chrome/url-under (prefix) path query))
