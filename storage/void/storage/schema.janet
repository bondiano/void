### void/storage/schema — the :file schema type.
###
### What a file field *stores* is a key, so that is what the type
### validates — in a form, in an entity, in an API document. The upload
### itself never meets the schema layer: by the time validation runs,
### the widget (or a controller's `save-upload!`) has already turned
### the part into a key.
###
### It is registered **at module load**, the void/proto pose: an entity
### is declared while a module loads, and `[:file {...}]` in a
### `defentity` normalizes right then — long before a bootstrap could
### resolve an extension point. ./init contributes it to
### `:void.core/schema-type` as well, so `plugin/inspect` and
### CONTRACTS.md show it next to every other custom type; registering
### twice is a replace, which is what the schema layer's registries do
### by design.
###
### The `:storage/*` props are annotations in the schema-layer sense —
### parsed and stored on the node, never consulted by validation,
### read by the projections that act on them:
###
###   :storage/accept     media types a form and the server both
###                       enforce: ["image/png" "image/*"]
###   :storage/max-bytes  the size the server refuses past
###   :storage/prefix     the key namespace uploads land under
###                       (default: the resource's own name)

(import void/core/schema :as schema)
(import ./key :as key)

(def types
  "The custom schema types this package registers."
  {:file {:validate (fn file-key? [v _] (key/valid? v))
          :message "expected a storage key (a relative slash-separated path)"}})

(eachp [name spec] types (schema/register-type! name spec))

(defn annotations
  ``The `:storage/*` props of a schema node, as a struct — what the
  form projection and the admin widget read. `db-annotations` is the
  same idea for `:db/*`.``
  [node]
  (freeze
    (tabseq [[k v] :pairs (get node :props {})
             :when (and (keyword? k) (string/has-prefix? "storage/" k))]
      k v)))
