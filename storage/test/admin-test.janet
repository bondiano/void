### The upload widget through the whole admin (ADR-0017): a declared
### resource with one `:file` field, and the four things that have to
### be true of it — the form says multipart, the control is a file
### input carrying the field's own :accept, a submitted file is stored
### and its *key* saved, and an edit that chooses no file keeps what is
### there.
###
### The application below declares nothing about storage beyond the
### schema annotation. That is the claim being tested: a column added
### to a `defentity` shows up in the back office, drawn by the widget
### the type resolves to, with no line in the resource declaration.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/admin :as admin)
(import void/admin/context :as admin-ctx)
(import void/authz :as authz)
(import void/db :as db)
(import void/http/multipart :as multipart)
(import void/storage :as storage)
(import void/test :as test)

(log/set-level! nil :error)

# -- the application -----------------------------------------------------

(db/defentity Photo
  {:id [:int {:db/pk true :db/type "integer"}]
   :title [:string {:min 1 :max 60 :db/type "text"}]
   # the whole of what this application says about uploads
   :image [:optional [:file {:db/type "text"
                             :storage/prefix "photos"
                             :storage/accept ["image/png" "image/jpeg"]
                             :storage/max-bytes 64}]]}
  :db/table "photos")

(admin/defresource-admin photos Photo
  :title "Photos"
  :list [:id :title :image]
  :detail [:id :title :image]
  :form [:title :image]
  :order-by [[:id :asc]])

(authz/defpolicy :staff "Everybody, in this test." [_] true)

(def plugins
  ["void/http/init" "void/html/init" "void/htmx/init"
   "void/db/init" "void/db-sqlite/init" "void/db/http"
   "void/crypto/init" "void/security/init"
   "void/authz/init" "void/authz/http"
   "void/admin/init"
   "void/storage/init" "void/storage/http" "void/storage/admin"])

(def root (string "tmp/admin-test-" (os/getpid)))
(def db-path (string (or (os/getenv "TMPDIR") "/tmp")
                     "/void-storage-admin-" (os/time) ".sqlite3"))

(defn- rm-rf [path]
  (case (os/stat path :mode)
    :directory (do (each e (os/dir path) (rm-rf (string path "/" e)))
                   (os/rmdir path))
    :file (os/rm path)
    nil))

(rm-rf root)
(os/mkdir "tmp")

(def boot
  (test/start! {:plugins plugins
                :profile :test
                :only [:http/kernel :db/pool :authz/registry :crypto/lib :storage/store]
                :config {:env @{}
                         :cli {:http {:port 0}
                               :db-sqlite {:path db-path}
                               :db {:n1-guard :off}
                               :security {:signing-key "0123456789abcdef0123456789abcdef"}
                               :storage {:local {:root root} :serve {:prefix "/files"}}
                               :admin {:access :staff}}}}))

(defer (do (test/stop! boot) (rm-rf root) (os/rm db-path))
  (db/execute-sql "DROP TABLE IF EXISTS photos" [] {:kind :write :prepared false})
  (db/execute-sql
    (string "CREATE TABLE photos (id integer primary key autoincrement, "
            "title text not null, image text)")
    [] {:kind :write :prepared false})

  (def c (test/client boot))
  (defn- text [resp] (test/text resp))
  (defn- csrf-of [resp]
    (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`))) (text resp))))

  (defn- upload [uri token parts]
    (def enc (multipart/encode parts))
    (test/inject c {:method :post :uri uri
                    :headers @{"x-csrf-token" token
                               "content-type" (enc :content-type)}
                    :body (enc :body)}))

  # -- the widget was chosen, and it says why -----------------------------

  (def entries (admin-ctx/widget-entries :photos))
  (assert (= :void.storage/upload (get-in entries [:image :widget :name]))
          "a :file field resolves to the upload widget")
  (assert (= :contributed (get-in entries [:image :why]))
          "by contribution, which is what `void admin widgets` prints")
  (assert (= :void.admin/form (get-in entries [:title :widget :name]))
          "and everything else still falls back to html/form's projection")

  # -- the form -----------------------------------------------------------

  (def new-page (test/inject c {:uri "/admin/photos/new"}))
  (assert (= 200 (new-page :status)))
  (def form (text new-page))
  (assert (string/find "enctype=\"multipart/form-data\"" form)
          "the form says multipart, because a widget on it needs one")
  (assert (string/find "type=\"file\"" form) "the control is a file input")
  (assert (string/find "accept=\"image/png,image/jpeg\"" form)
          "carrying the media types the schema annotated")
  (def token (csrf-of new-page))

  # -- creating with a file -----------------------------------------------

  (def created (upload "/admin/photos" token
                       [{:name "title" :value "a cat"}
                        {:name "image" :filename "cat.png"
                         :content-type "image/png" :value "PNG-BYTES"}]))
  (assert (index-of (created :status) [303 204])
          (string/format "the create redirects (%d)" (created :status)))

  (def row (db/one Photo {:where [:= :title "a cat"]}))
  (assert row "the row was written")
  (assert (string/has-prefix? "photos/" (row :image))
          "and what it holds is a key in the field's namespace")
  (assert (string/has-suffix? ".png" (row :image)))
  (assert (= "PNG-BYTES" (string (storage/get (row :image))))
          "with the bytes in the store")

  # -- what the desk shows ------------------------------------------------

  (def listing (text (test/inject c {:uri "/admin/photos"})))
  (assert (string/find (string "/files/" (row :image)) listing)
          "the list cell links at the object through the store's own url")
  (assert (string/find "<img" listing) "and draws an image as a thumbnail")

  (def detail (text (test/inject c {:uri (string "/admin/photos/" (row :id))})))
  (assert (string/find "storage-preview" detail)
          "the detail page draws the larger preview")

  # -- editing without choosing a file ------------------------------------

  (def edit-page (test/inject c {:uri (string "/admin/photos/" (row :id) "/edit")}))
  (def etoken (csrf-of edit-page))
  (assert (string/find (string "/files/" (row :image)) (text edit-page))
          "the edit form shows what is stored now")

  (def renamed (upload (string "/admin/photos/" (row :id)) etoken
                       [{:name "title" :value "the same cat"}
                        # what a browser sends for a file input nobody
                        # touched: a part with no filename and no bytes
                        {:name "image" :filename "" :value ""}]))
  (assert (index-of (renamed :status) [303 204]))
  (def after (db/find Photo (row :id)))
  (assert (= "the same cat" (after :title)) "the other field was updated")
  (assert (= (row :image) (after :image))
          "and an untouched file input did not erase the object")

  # -- replacing ------------------------------------------------------------

  (def replaced (upload (string "/admin/photos/" (row :id)) etoken
                        [{:name "title" :value "the same cat"}
                         {:name "image" :filename "other.png"
                          :content-type "image/png" :value "OTHER"}]))
  (assert (index-of (replaced :status) [303 204]))
  (def after2 (db/find Photo (row :id)))
  (assert (not= (row :image) (after2 :image)) "a chosen file replaces the key")
  (assert (= "OTHER" (string (storage/get (after2 :image)))))
  (assert (= "PNG-BYTES" (string (storage/get (row :image))))
          "and the old object is still there — sweeping orphans is a decision, not a side effect")

  # -- what the server refuses whatever the browser filtered --------------

  (def wrong-type (upload "/admin/photos" token
                          [{:name "title" :value "a script"}
                           {:name "image" :filename "x.svg"
                            :content-type "image/svg+xml" :value "<svg/>"}]))
  (assert (= 422 (wrong-type :status))
          "a media type the field does not take is refused server-side")
  (assert (string/find "image/png" (text wrong-type))
          "and the refusal is a message on the field, where the operator chose the file")
  (assert (string/find "x.svg" (text wrong-type))
          "naming the file it is about")
  (assert (string/find "type=\"file\"" (text wrong-type))
          "on a form that re-rendered rather than a status line with no form")

  (def too-big (upload "/admin/photos" token
                       [{:name "title" :value "a big cat"}
                        {:name "image" :filename "big.png"
                         :content-type "image/png" :value (string/repeat "x" 65)}]))
  (assert (= 422 (too-big :status)) "and so is a file over the field's limit")

  (assert (nil? (db/one Photo {:where [:= :title "a script"]}))
          "neither of them wrote a row")

  # -- a file the schema did not ask for ----------------------------------

  (def no-file (upload "/admin/photos" token [{:name "title" :value "no image"}]))
  (assert (index-of (no-file :status) [303 204])
          "an optional upload left out is not an error")
  (assert (nil? ((db/one Photo {:where [:= :title "no image"]}) :image))
          "and the column stays empty"))

(printf "admin-test: ok")
