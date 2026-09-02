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

(var current
  ``The running dash context, set by ./init's :before-start hook:
  :boot :config :prefix :title :open? :access :allow-actions?
  :started-at :datastar? :tiles :route-meta :htmx-src :htmx-integrity
  :assets.``
  nil)

(defn context
  "The dash context, or a refusal naming why it is not there."
  []
  (or current
      (error "void/dash is not booted — plugin/start! builds the dash context at :before-start")))

(defn setting
  "One key of the context."
  [k &opt dflt]
  (get (context) k dflt))

(defn boot
  "The boot value the dashboard projects."
  []
  (setting :boot))

(defn prefix
  "Where the dashboard is mounted ([:dash :prefix], default \"/dash\")."
  []
  (setting :prefix "/dash"))

(defn at
  ``A URL under the dash prefix: (at "/routes"), (at "/why" {"key"
  "http/server"}). Query is a table of already-stringable values; nil
  and empty values drop out — "the same URL without the filter" is one
  expression rather than a branch.``
  [path &opt query]
  (def full (string (prefix) path))
  (def pairs*
    (sorted (seq [[k v] :pairs (or query {})
                  :when (and (not (nil? v)) (not (empty? (string v))))]
              (string k "=" v))))
  (if (empty? pairs*)
    full
    (string full "?" (string/join pairs* "&"))))
