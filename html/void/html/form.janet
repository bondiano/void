### void/html/form — form helpers from the schema layer (SPEC.md §5.4,
### ADR-0008).
###
### One map schema drives validation, docs and now markup: field-specs
### projects the schema's fields into plain control descriptions
### (control kind, input type, constraint attributes, required flag)
### and the render helpers turn those into hiccup — filled with
### submitted values and annotated with schema/check errors, so the
### validate-and-re-render loop is one round trip. The CSRF slot: when
### a non-GET form renders and (dyn :void.html/csrf) is bound to a
### function, its hiccup is spliced right after the opening <form> tag
### — void/security binds it in wave 3, nothing renders until then.

(import void/core/schema :as schema)

(defn params
  ``Submitted form data (string keys, as void/http's parsing
  middleware leaves it in (req :form)) with the keys keywordized —
  the shape map schemas address.``
  [form]
  (tabseq [[k v] :pairs (or form {})]
    (if (bytes? k) (keyword k) k) v))

(defn check
  ``schema/check over submitted form data: keywordize the string keys
  and validate in coercion mode ("42" -> 42, "true" -> true, "admin"
  -> :admin). Returns {:value coerced :errors [...]} — feed :errors
  and the original form straight back into `form`/`fields` to
  re-render an invalid submission:

      (def result (form/check SignUp (req :form)))
      (if (empty? (result :errors))
        (create-user! (result :value))
        (html/page (form/form SignUp {:action "/signup"
                                      :values (req :form)
                                      :errors (result :errors)})))``
  [sch form &opt opts]
  (schema/check sch (params form) (merge {:coerce true} (or opts {}))))

(defn- unwrap
  "Strip :optional/:ref wrappers -> [inner-node required?]."
  [node]
  (case (node :type)
    :optional (let [[inner _] (unwrap (first (node :children)))]
                [inner false])
    :ref (let [name (get-in node [:props :name])]
           (unwrap (or (schema/lookup name)
                       (errorf "schema %q is not registered" name))))
    [node true]))

(defn- humanize [k]
  (def s (string/replace-all "-" " " (string k)))
  (if (empty? s)
    s
    (string (string/ascii-upper (string/slice s 0 1)) (string/slice s 1))))

(def- format-input-types
  {:email "email" :uri "url" :date "date"})

(defn- control-spec
  "Control kind and html attributes for one unwrapped schema node."
  [node]
  (def props (node :props))
  (case (node :type)
    :boolean {:control :checkbox}
    :enum {:control :select
           :options (props :values)}
    :int {:control :input :type "number"
          :attrs {:min (props :min) :max (props :max)}}
    :number {:control :input :type "number"
             :attrs {:min (props :min) :max (props :max) :step "any"}}
    # string length lives in :min/:max props (void/core/schema bounds)
    :string {:control :input
             :type (get format-input-types (props :format) "text")
             :attrs {:minlength (props :min)
                     :maxlength (props :max)}}
    {:control :input :type "text"}))

(defn field-specs
  ``Project a map schema into field descriptions, in schema key order:

      [{:name :email :label "Email" :required true
        :control :input :type "email" :attrs {...}} ...]

  :control is :input, :checkbox, :select (with :options) or :textarea.
  opts {:fields {key overrides}} merges per-field overrides in —
  {:control :textarea}, {:label "..."}, {:attrs {...}} — the escape
  hatch for what a schema cannot express.``
  [sch &opt opts]
  (def n (schema/normalize sch))
  (unless (= :map (n :type))
    (errorf "field-specs expects a map schema, got %q" (n :type)))
  (def overrides (get opts :fields {}))
  (seq [[k child] :in (n :children)]
    (def [inner required?] (unwrap child))
    (def base (control-spec inner))
    (def over (get overrides k {}))
    (merge {:name k
            :label (humanize k)
            :required required?}
           base
           over
           {:attrs (merge (get base :attrs {}) (get over :attrs {}))})))

(defn- field-value [values k]
  (when values
    (def v (get values k))
    (if (nil? v) (get values (string k)) v)))

(defn- field-id [spec]
  (string "field-" (spec :name)))

(defn input
  "Hiccup for one control (no label, no errors)."
  [spec &opt value]
  (def name (string (spec :name)))
  (def id (field-id spec))
  (def required (when (spec :required) true))
  (case (spec :control)
    :checkbox
    [:input {:type "checkbox" :name name :id id :value "true"
             :checked (when value true)}]

    :select
    [:select {:name name :id id :required required}
     (seq [o :in (spec :options)]
       [:option {:value (string o)
                 :selected (when (or (= o value) (= (string o) value)) true)}
        (humanize o)])]

    :textarea
    [:textarea (merge {:name name :id id :required required}
                      (get spec :attrs {}))
     (when (not (nil? value)) (string value))]

    :input
    [:input (merge {:type (get spec :type "text") :name name :id id
                    :required required
                    :value (when (not (nil? value)) (string value))}
                   (get spec :attrs {}))]

    (errorf "unknown form control %q for field %q" (spec :control) (spec :name))))

(defn errors-by-field
  "Group schema/check errors by their top-level path key; errors with
  an empty path land under :form."
  [errors]
  (def out @{})
  (each e (or errors [])
    (def k (if (empty? (e :path)) :form (first (e :path))))
    (array/push (or (out k) (let [a @[]] (put out k a) a)) e))
  out)

(defn field
  "Hiccup for one labeled field: label, control, error list."
  [spec &opt value errs]
  [:div {:class (string "field field-" (spec :name)
                        (if (empty? (or errs [])) "" " field-invalid"))}
   [:label {:for (field-id spec)} (spec :label)]
   (input spec value)
   (when (and errs (not (empty? errs)))
     [:ul {:class "field-errors"}
      (seq [e :in errs] [:li (schema/error-str e)])])])

(defn fields
  ``Labeled fields for every entry of a map schema.

  opts: :values (submitted or entity values, keyword or string keys),
  :errors (schema/check errors), :fields (per-field spec overrides,
  see field-specs).``
  [sch &opt opts]
  (def by-field (errors-by-field (get opts :errors)))
  (seq [spec :in (field-specs sch opts)]
    (field spec
           (field-value (get opts :values) (spec :name))
           (get by-field (spec :name)))))

(defn form
  ``A complete form for a map schema:

      (form/form CreateUser
        {:action "/users" :values (req :form) :errors (result :errors)})

  opts: :action (required), :method (:post default, or :get),
  :submit (button label, "Save"), :attrs (extra <form> attributes),
  plus everything `fields` accepts. Form-level errors (empty path)
  render before the fields; the CSRF slot renders on non-GET forms
  when (dyn :void.html/csrf) is bound.``
  [sch opts]
  (def method (get opts :method :post))
  (unless (in {:get true :post true} method)
    (errorf "form method must be :get or :post, got %q" method))
  (def form-errors (get (errors-by-field (get opts :errors)) :form))
  [:form (merge {:action (or (opts :action)
                             (error "form opts need an :action"))
                 :method (string method)}
                (get opts :attrs {}))
   (when-let [csrf (and (= :post method) (dyn :void.html/csrf))]
     (csrf))
   (when form-errors
     [:ul {:class "form-errors"}
      (seq [e :in form-errors] [:li (schema/error-str e)])])
   (fields sch opts)
   [:button {:type "submit"} (get opts :submit "Save")]])
