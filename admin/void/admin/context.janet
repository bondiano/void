### void/admin/context — the boot-time settings of the admin, in one
### place so that the view, the mount and the handlers can read them
### without importing each other in a circle.
###
### It is assembled once, at :before-start, from the [:admin] config slice
### and the four extension points the plugin owns — and then it is only
### read. The admin keeps no other process state that affects correctness:
### the registry is derived from code, the widget resolution is derived
### from the registry, and the state of a list lives in the URL.

(var current
  ``The running admin context, set by ./init's :before-start hook:
  :prefix :title :per-page :select-limit :inline-limit :layout
  :stylesheet :access :widgets :pages :menu :dashboard :history
  :hooks :bulk-runner :resolved :assets.``
  nil)

(defn context
  "The admin context, or a refusal naming why it is not there."
  []
  (or current
      (error "void/admin is not booted — plugin/start! builds the admin context at :before-start")))

(defn setting
  "One key of the context."
  [k &opt dflt]
  (get (context) k dflt))

(defn prefix
  "Where the admin is mounted ([:admin :prefix], default \"/admin\")."
  []
  (setting :prefix "/admin"))

(defn base
  "The URL prefix of one resource: \"/admin/articles\"."
  [desc]
  (string (prefix) (desc :path)))

(defn at
  ``A URL under the admin prefix: (at "/jobs"), (at "/jobs" {"state"
  :dead}). Query is a table of already-stringable values; nil and empty
  values drop out, which is what makes "the same URL without the
  filter" one expression rather than a branch.

  It exists because `[:admin :prefix]` is config and a contribution is
  a value frozen at load: a plugin that mounts a `:void.admin/page`
  cannot write down where its own page will be, and asks here instead.``
  [path &opt query]
  (def full (string (prefix) path))
  (def pairs*
    (sorted (seq [[k v] :pairs (or query {})
                  :when (and (not (nil? v)) (not (empty? (string v))))]
              (string k "=" v))))
  (if (empty? pairs*)
    full
    (string full "?" (string/join pairs* "&"))))

(defn url
  ``A URL inside a resource: (url desc "/7/edit"), (url desc) for the
  list — `at`, over the resource's own path.``
  [desc &opt suffix query]
  (at (string (desc :path) (or suffix "")) query))

(defn widget-entries
  "The widget resolution of one resource, computed at mount."
  [rname]
  (get-in (context) [:resolved rname] {}))

(defn widget-entry
  "The resolved widget of one field, or nil."
  [rname fname]
  (get (widget-entries rname) fname))
