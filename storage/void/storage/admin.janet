### void/storage-admin — the upload widget (ADR-0039 §6).
###
### The seam ADR-0029 §4 left open, used from the other side: a field
### whose schema says `:file` is drawn by this widget in every admin
### form, list and detail page — a file input with the field's own
### `:storage/accept` on it, a thumbnail where the value is an image, a
### link where it is not — and *parsed* by it: the widget reads the
### file part off the request, enforces `:storage/accept` and
### `:storage/max-bytes` (the server's half of the accept attribute it
### rendered), stores the bytes through the active store and hands the
### schema layer the key string. The entity saves a text column; the
### admin learned nothing about buckets.
###
### An edit that chooses no file keeps the existing object: the parse
### answers nil and the field stays out of the update — the same
### convention Rails and Django settled on, because "empty input means
### delete" is a data-loss footgun. Replacing an object leaves the old
### one in the store; sweeping orphans is a maintenance decision
### (a job, `void storage rm`), not a side effect of an update.

(import void/admin/widget :as admin-widget)
(import void/core/plugin :as plugin)
(import void/http/static :as static)
(import ./schema :as sschema)
(import ./state :as state)
(import ./upload :as upload)

(defn- image-key? [k]
  (string/has-prefix? "image/" (static/mime-type (string k))))

(defn- basename [k]
  (def s (string k))
  (if-let [i (last (string/find-all "/" s))]
    (string/slice s (inc i))
    s))

(defn- shown
  "The value as hiccup: a thumbnail for an image, a named link
  otherwise, the em dash for nothing — sized by mode."
  [value mode]
  (cond
    (nil? value) (admin-widget/text-of nil)
    (let [url (state/url (string value))]
      (cond
        (nil? url) (admin-widget/text-of value)
        (image-key? value)
        [:a {:href url :target "_blank"}
         [:img {:src url :alt (basename value)
                :class (if (= :detail mode) "storage-preview" "storage-thumb")}]]
        [:a {:href url :target "_blank"} (basename value)]))))

(defn- accept-attr [field]
  (when-let [accept (get (sschema/annotations (field :node)) :storage/accept)]
    (string/join (map string accept) ",")))

(def upload-widget
  "The :void.admin/widget contribution for :file fields."
  {:name :void.storage/upload
   :doc "a file input storing through :void/storage-store; the value is the key"
   :types [:file]
   :encoding :multipart
   :render
   (fn upload-render [ctx]
     (def field (ctx :field))
     [:span {:class "storage-upload"}
      (when (ctx :value)
        [:span {:class "storage-current"}
         (shown (ctx :value) :form)
         # what an untouched input means, said where the operator looks
         [:small " current — choose a file to replace it"]])
      [:input {:type "file"
               :name (ctx :name) :id (ctx :id)
               :accept (accept-attr field)
               :required (when (and (field :required)
                                    (nil? (ctx :value))
                                    (not (ctx :readonly)))
                           true)
               :disabled (when (ctx :readonly) true)}]])
   :display
   (fn upload-display [ctx]
     (shown (ctx :value) (ctx :mode)))
   :parse
   (fn upload-parse [_raw ctx]
     (def field (ctx :field))
     (def part (upload/find-part (get-in ctx [:request :multipart])
                                 (field :name)))
     (when part
       (def props (sschema/annotations (field :node)))
       (def opts {:prefix (or (props :storage/prefix)
                              (string (get-in ctx [:resource :name] "uploads")))
                  :accept (props :storage/accept)
                  :max-bytes (props :storage/max-bytes)})
       # Two failures, and they are not the same failure. What the
       # operator chose can be wrong — the wrong type, too many bytes —
       # and that is a message on the field. What happens *after* the
       # part is accepted (no store, a bucket that refuses, a full disk)
       # is the composition's problem, and it goes to the panic guard
       # like any other, because an operator cannot fix it by choosing
       # a different file.
       (def [ok refusal] (protect (upload/check-part! part opts)))
       (unless ok (admin-widget/refuse! refusal))
       ((upload/save-part! part opts) :key)))
   :assets
   {:style (string ".storage-thumb{max-height:40px;max-width:80px;display:block}"
                   ".storage-preview{max-height:200px;max-width:320px;display:block}"
                   ".storage-current{display:block;margin-bottom:.4rem}")}})

(plugin/contribute! :void.admin/widget upload-widget)

(plugin/defplugin void/storage-admin
  :doc "The admin upload widget: :file fields render a file input, list and detail pages show a thumbnail or a link, and a submitted file is stored through :void/storage-store with the field's :storage/accept and :storage/max-bytes enforced server-side."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/storage ">=0.0.1" :void/admin ">=0.0.1"})
