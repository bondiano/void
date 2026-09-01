# The seam between a multipart part and a store: what counts as an
# upload, what the server refuses whatever the browser filtered, and
# what a caller gets back.

(import ../test-support/paths)
(import void/http/multipart :as multipart)
(import void/storage/local :as local)
(import void/storage/state :as state)
(import void/storage/store :as store)
(import void/storage/upload :as upload)

(def root (string "tmp/upload-test-" (os/getpid)))

(defn- rm-rf [path]
  (case (os/stat path :mode)
    :directory (do (each e (os/dir path) (rm-rf (string path "/" e)))
                   (os/rmdir path))
    :file (os/rm path)
    nil))

(rm-rf root)
(os/mkdir "tmp")

(def st (store/normalize (local/store (local/make {:local {:root root}
                                                   :serve {:prefix "/storage"}}))))

# -- what is a file part -------------------------------------------------

(def png @{:name "image" :filename "me.png" :content-type "image/png" :value "PNG"})
(def field @{:name "title" :filename nil :value "a cat"})
(def empty-input @{:name "image" :filename "" :content-type "application/octet-stream" :value ""})

(assert (upload/file-part? png))
(assert (not (upload/file-part? field)) "a plain form field is not an upload")
(assert (not (upload/file-part? empty-input))
        "a file input left empty submits an empty part — that is \"no file\", not a zero-byte file")

(assert (= png (upload/find-part [field png] "image")))
(assert (= png (upload/find-part [field png] :image)) "a keyword names the same field")
(assert (nil? (upload/find-part [field empty-input] "image"))
        "and an empty input is not found as one")
(assert (nil? (upload/find-part [] "image")))
(assert (nil? (upload/find-part nil "image")) "no multipart at all is not an error")

# -- what the server enforces --------------------------------------------

(assert (upload/check-part! png {}) "no options, no refusals")
(assert (upload/check-part! png {:accept ["image/png" "image/jpeg"]}))
(assert (upload/check-part! png {:accept ["image/*"]}) "a wildcard accepts the type")
(assert (upload/check-part! png {:max-bytes 3}) "the limit is inclusive")

(each [opts reason]
  [[{:accept ["image/jpeg"]} "a type the field does not take"]
   [{:accept ["text/*"]} "a wildcard that does not cover it"]
   [{:max-bytes 2} "more bytes than the field allows"]]
  (def [ok err] (protect (upload/check-part! png opts)))
  (assert (not ok) (string reason " is refused"))
  (assert (string/find "me.png" (string err))
          "and the refusal names the file the operator chose"))

# a part with no declared type is refused by a field that names types:
# "unknown" is not "allowed", and the browser is not the authority
(def untyped @{:name "image" :filename "x.png" :value "PNG"})
(def [ok _] (protect (upload/check-part! untyped {:accept ["image/png"]})))
(assert (not ok) "a part with no content-type does not pass an :accept list")

# the media type is compared without its parameters
(def charset @{:name "f" :filename "a.txt" :content-type "text/plain; charset=utf-8" :value "hi"})
(assert (upload/check-part! charset {:accept ["text/plain"]})
        "a content-type's parameters are not part of the comparison")

# -- saving --------------------------------------------------------------

(with-dyns [state/storage-dyn st]

  (def meta (upload/save-part! png {:prefix "products"}))
  (assert (string/has-prefix? "products/" (meta :key)) "the key lands in the given namespace")
  (assert (string/has-suffix? ".png" (meta :key)) "and keeps the extension")
  (assert (= "me.png" (meta :filename)) "the original name comes back as metadata")
  (assert (= 3 (meta :size)))
  (assert (= "image/png" (meta :content-type)) "the part's own type is what was stored")
  (assert (= "PNG" (string (state/fetch (meta :key)))) "and the bytes are in the store")

  # the caller may name the key instead of generating one
  (def fixed (upload/save-part! png {:key "logos/current.png"}))
  (assert (= "logos/current.png" (fixed :key)))

  # a refusal happens before anything is written
  (def before (length (os/dir (string root "/products"))))
  (def [ok _] (protect (upload/save-part! png {:prefix "products" :max-bytes 1})))
  (assert (not ok) "an oversize part is refused")
  (assert (= before (length (os/dir (string root "/products"))))
          "and nothing was stored on the way to refusing it")

  # -- the controller one-liner ------------------------------------------

  (def enc (multipart/encode [{:name "title" :value "a cat"}
                              {:name "image" :filename "cat.png"
                               :content-type "image/png" :value "REAL-PNG"}]))
  (def parts (multipart/parse (enc :body) (enc :boundary)))
  (def req @{:multipart parts :form (multipart/fields parts)})

  (assert (= "a cat" (string (get-in req [:form "title"])))
          "the plain fields are where they always were")
  (assert (nil? (get-in req [:form "image"]))
          "and the file is not among them — which is the gap this module is")
  (assert (= "cat.png" (get-in (multipart/files parts) ["image" :filename]))
          "multipart/files is the file half of the same fold")

  (def saved (upload/save-upload! req "image" {:prefix "cats"}))
  (assert (string/has-prefix? "cats/" (saved :key)))
  (assert (= "REAL-PNG" (string (state/fetch (saved :key)))))

  (assert (nil? (upload/save-upload! req "avatar"))
          "an optional upload nobody filled in is nil, not an error")

  (def [ok2 err2] (protect (upload/save-part! field {})))
  (assert (not ok2) "save-part! wants a file part")
  (assert (string/find ":filename" (string err2)) "and says what one is"))

(rm-rf root)
(printf "upload-test: ok")
