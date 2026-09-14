(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/html/form :as form)
(import void/html/hiccup :as hiccup)
(import void/html :as html)
(import void/http/ring :as ring)
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
            `required` `value="a@b.co"`]
  (assert (string/find part email-html) part))

(assert (string/find `checked` (render (form/input (by-name :subscribed) true))))
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

# -- password, hidden, help: what the schema annotates ------------------
#
# Three annotations validation never reads and the form does: the
# :password format (the control is masked), :html/hidden (a value the
# page carries and the visitor does not see), and :label / :doc (the
# words, and the help text under the control).

(def Secret {:token [:string {:format :password}]})
(def token-spec (first (form/field-specs Secret)))
(assert (= "password" (token-spec :type))
        "format :password -> input type password")
(assert (string/find `type="password"` (render (form/input token-spec "hunter2")))
        "the control is masked — the page cannot read the value back")

(def Annotated
  {:csrf [:string {:html/hidden true}]
   :name [:string {:label "Your name" :doc "As you want to be addressed"}]})
(def aspecs (form/field-specs Annotated))

(def csrf (find |(= :csrf ($ :name)) aspecs))
(assert (= :hidden (csrf :control)) ":html/hidden projects to a hidden control")
(def hidden-html (render (form/field csrf "tok")))
(each part [`type="hidden"` `name="csrf"` `value="tok"`]
  (assert (string/find part hidden-html) part))
(assert (nil? (string/find "<label" hidden-html))
        "a hidden field is the input alone — a label for what nobody sees is an empty label")
(assert (nil? (string/find `class="field` hidden-html))
        "and no field wrapper either")

(def name-spec (find |(= :name ($ :name)) aspecs))
(assert (= "Your name" (name-spec :label)) ":label overrides the humanized key")
(assert (= "As you want to be addressed" (name-spec :help)) "and :doc becomes :help")
(def labeled (render (form/field name-spec "ada")))
(each part [`<label for="field-name">Your name</label>`
            `<p class="field-help">As you want to be addressed</p>`]
  (assert (string/find part labeled) part))
(assert (nil? (string/find "field-help" (render (form/field (by-name :email) "a@b.co"))))
        "a field without :doc has no help paragraph")

# :render — the seam a widget goes through, so a widget field and a
# plain field are one block with one class vocabulary
(def wspecs
  (form/field-specs SignUp
    {:fields {:email {:render (fn [spec value]
                                [:div {:class "vd-widget"}
                                 [:input {:name (spec :name) :value value}]])}}}))
(def emailed (render (form/field (find |(= :email ($ :name)) wspecs) "a@b.co")))
(assert (string/find `class="vd-widget"` emailed)
        "the spec's :render draws the control instead of input")
(assert (string/find `value="a@b.co"` emailed) "with the value it was given")
(assert (string/find `<label for="field-email">` emailed)
        "inside the same labeled block a plain field gets")

# -- submit: check, then one of two continuations ------------------------

(var saved nil)
(def ok-resp
  (form/submit SignUp @{"email" "a@b.co" "age" "30" "role" "user"}
    {:ok (fn [v] (set saved v) (ring/redirect "/"))
     :invalid (fn [_ _] (error "must not run"))}))
(assert (= 302 (ok-resp :status)) "the ok branch's response passes through untouched")
(assert (= 30 (saved :age)) "and its continuation got the coerced value")

(def bad @{"email" "nope" "age" "12" "role" "user"})
(var got-values nil)
(var got-errors nil)
(def invalid-resp
  (form/submit SignUp bad
    {:ok (fn [v] (error "must not run"))
     :invalid (fn [values errors]
                (set got-values values)
                (set got-errors errors)
                (html/page [:h1 "again"] {}))}))
(assert (deep= (freeze bad) (freeze got-values))
        "the invalid continuation gets the submitted form, to refill the controls")
(assert (= 2 (length got-errors)) "and the errors, to annotate them")
(assert (= 422 (invalid-resp :status))
        "a re-rendered form is a refusal: a page response becomes 422")

(def with-status (form/submit SignUp bad
                   {:ok (fn [v] (error "must not run"))
                    :invalid (fn [_ _] (ring/redirect "/login"))}))
(assert (= 302 (with-status :status))
        "a response that already has a status keeps it")
(def plain-200 (form/submit SignUp bad
                 {:ok (fn [v] (error "must not run"))
                  :invalid (fn [_ _] (ring/response 200 "raw body"))}))
(assert (= 200 (plain-200 :status))
        "a non-view 200 keeps its status — 422 is for re-rendered forms")

(assert (not (first (protect (form/submit SignUp bad {}))))
        "submit without :ok refuses to guess")
(assert (not (first (protect
                      (form/submit SignUp @{"email" "a@b.co" "age" "30" "role" "user"} {}))))
        "and so does submit without :invalid")

# -- snapshot ------------------------------------------------------------

(assert (test/snapshot "form-signup"
                       (render (form/form SignUp {:action "/signup"
                                                  :values bad
                                                  :errors (result :errors)
                                                  :fields {:bio {:control :textarea}}}))))

(print "form-test: ok")
