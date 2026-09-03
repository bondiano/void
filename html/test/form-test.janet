(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/html/form :as form)
(import void/html/hiccup :as hiccup)
(import void/test :as test)

(schema/defschema SignUp
  {:email [:string {:format :email}]
   :age [:int {:min 18 :max 130}]
   # string length bounds are :min/:max (void/core/schema), the same
   # props the validator enforces — they project to minlength/maxlength
   :bio [:optional [:string {:max 200}]]
   :role [:enum :admin :user]
   :subscribed [:optional :boolean]})

# -- field-specs: the schema projected into control descriptions ---------

(def specs (form/field-specs SignUp))
(def by-name (tabseq [s :in specs] (s :name) s))

(assert (= 5 (length specs)))
(assert (deep= (map |($ :name) specs) @[:age :bio :email :role :subscribed])
        "fields follow schema key order")

(assert (= :input ((by-name :email) :control)))
(assert (= "email" ((by-name :email) :type)) "format :email -> input type email")
(assert ((by-name :email) :required))

(assert (= "number" ((by-name :age) :type)))
(assert (= 18 (get-in by-name [:age :attrs :min])))
(assert (= 130 (get-in by-name [:age :attrs :max])))

(assert (not ((by-name :bio) :required)) ":optional unwraps to required false")
(assert (= 200 (get-in by-name [:bio :attrs :maxlength])))

(assert (= :select ((by-name :role) :control)))
(assert (deep= [:admin :user] (freeze ((by-name :role) :options))))

(assert (= :checkbox ((by-name :subscribed) :control)))

# per-field overrides are the escape hatch
(def with-over
  (form/field-specs SignUp {:fields {:bio {:control :textarea :label "About you"}}}))
(def bio-over (find |(= :bio ($ :name)) with-over))
(assert (= :textarea (bio-over :control)))
(assert (= "About you" (bio-over :label)))

# a ref field resolves through the registry
(schema/register! :Money [:int {:min 0}])
(def ref-specs (form/field-specs {:price :Money}))
(assert (= "number" ((first ref-specs) :type)) ":ref unwraps to the target type")

# -- rendering: values, errors, controls ---------------------------------

(defn render [x] (hiccup/render-string x))

(def email-html (render (form/input (by-name :email) "a@b.co")))
(each part [`type="email"` `name="email"` `id="field-email"`
            `required="true"` `value="a@b.co"`]
  (assert (string/find part email-html) part))

(assert (string/find `checked="true"` (render (form/input (by-name :subscribed) true))))
(assert (nil? (string/find "checked" (render (form/input (by-name :subscribed) nil)))))

(def role-html (render (form/input (by-name :role) "user")))
(assert (string/find ">Admin</option>" role-html))
(def sel-at (string/find "selected" role-html))
(assert (and sel-at (> sel-at (string/find ">Admin</option>" role-html)))
        "string values (submitted forms) select only the matching option")

# form/check bridges submitted string keys to the schema world
(assert (deep= @{:email "a@b.co"} (form/params @{"email" "a@b.co"})))

(def ok-result (form/check SignUp @{"email" "a@b.co" "age" "30" "role" "user"}))
(assert (empty? (ok-result :errors)))
(assert (= 30 (get-in ok-result [:value :age])) "coercion mode is on")

# invalid submission: values come back, errors attach to their fields
(def bad @{"email" "nope" "age" "12" "role" "user"})
(def result (form/check SignUp bad))
(assert (= 2 (length (result :errors))) "bad email + under-age")

(def html (render (form/form SignUp {:action "/signup"
                                     :values bad
                                     :errors (result :errors)})))
(assert (string/find `action="/signup"` html))
(assert (string/find `method="post"` html))
(assert (string/find `value="nope"` html) "submitted values re-render")
(assert (string/find "field-invalid" html))
(assert (string/find `<ul class="field-errors">` html))
(assert (string/find "is not a valid" html) "schema error text renders")
(assert (string/find `<button type="submit">Save</button>` html))
(assert (nil? (string/find "csrf" html)) "no CSRF markup until the slot is bound")

# the CSRF slot: void/security will bind :void.html/csrf in wave 3
(def with-csrf
  (with-dyns [:void.html/csrf
              (fn [] [:input {:type "hidden" :name "csrf" :value "tok"}])]
    (render (form/form SignUp {:action "/signup"}))))
(each part [`type="hidden"` `name="csrf"` `value="tok"`]
  (assert (string/find part with-csrf) part))

(def get-form
  (with-dyns [:void.html/csrf (fn [] [:input {:name "csrf"}])]
    (render (form/form SignUp {:action "/search" :method :get}))))
(assert (nil? (string/find "csrf" get-form)) "GET forms skip the CSRF slot")

(assert (not (first (protect (form/form SignUp {:action "/x" :method :delete}))))
        "only :get and :post are HTML form methods")

# -- file fields, and what they do to the form ---------------------------
#
# The :file type is void/storage's; this projection is void/html's, and it
# works on any schema that uses one — the type is registered here so the
# assertions stand without that package.

(schema/register-type! :file {:validate (fn [v _] (string? v))})

(def Avatar
  {:name [:string {:min 1}]
   :photo [:file {:storage/accept ["image/png" "image/jpeg"]}]})

(def specs (form/field-specs Avatar))
(def photo (find |(= :photo ($ :name)) specs))
(assert (= :file (photo :control)) "a :file field is a file control")
(assert (= "image/png,image/jpeg" (get-in photo [:attrs :accept]))
        "carrying the media types the schema annotated")

(def avatar-form (render (form/form Avatar {:action "/me" :values {:photo "a/b.png"}})))
(assert (string/find `enctype="multipart/form-data"` avatar-form)
        "a form with a file control says multipart — a form that forgot would submit the filename and drop the file")
(assert (string/find `type="file"` avatar-form))
(assert (nil? (string/find `value="a/b.png"` avatar-form))
        "and carries no value: a file input's value is not scriptable, so re-rendering cannot restore the choice")

(assert (nil? (string/find "enctype" (render (form/form SignUp {:action "/signup"}))))
        "a form with no file control is left alone")

# -- snapshot ------------------------------------------------------------

(assert (test/snapshot "form-signup"
                       (render (form/form SignUp {:action "/signup"
                                                  :values bad
                                                  :errors (result :errors)
                                                  :fields {:bio {:control :textarea}}}))))

(print "form-test: ok")
