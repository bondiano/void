### void/admin/widget — the widget contract and its resolution
### (ADR-0029 §4).
###
### A widget is a **table of functions**, one of them required. The
### other five exist because each answers a question that would
### otherwise be answered by a special case inside the admin itself:
###
###   :render   the control in a form                      (required)
###   :display  the cell in a list and the row on a detail page
###   :filter   the control in the filter panel
###   :parse    the string a form submitted -> a domain value
###   :assets   style/script glued into the layout once per page
###   :routes   the widget's own server routes — FK autocomplete needs
###             an endpoint, and a widget that cannot ask for one turns
###             autocompletion into a feature of the core
###
### **Resolution happens once, at mount, per field** — never per row.
### A list of fifty rows calls `:display` fifty times and resolves
### nothing. The order is: the `:widget` named on the field, then the
### contributions whose `:types`/`:match` fit (highest `:priority`
### first), then the link widget when the column is a foreign key,
### then `html/form` — which already projects :string/:int/:enum/
### :boolean out of a schema and must not learn to do it twice.
###
### The result of the resolution is printable (`void admin widgets`):
### "why is this field drawn like that" is a question a command
### answers, not a question answered by reading sources.

(import void/db :as db)
(import void/html/form :as form)
(import void/html/hiccup :as hiccup)
(import void/http/router :as router)
(import ./resource :as res)

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

# -- normalization -------------------------------------------------------

(def- allowed-keys
  {:name true :doc true :types true :match true :priority true
   :render true :display true :filter true :parse true :assets true
   :routes true :encoding true})

(defn normalize
  "Validate a widget declaration — the shape both the extension point
  and an anonymous `:widget` table have to have."
  [w]
  (unless (dictionary? w)
    (errorf "an admin widget must be a table, got %q" w))
  (eachk k w
    (unless (in allowed-keys k)
      (errorf "admin widget %q: unknown key %q (allowed: %s)"
              (get w :name :anonymous) k
              (string/join (map |(string/format "%q" $) (sorted (keys allowed-keys))) " "))))
  (unless (callable? (get w :render))
    (errorf "admin widget %q: :render is required and must be a function"
            (get w :name :anonymous)))
  (each k [:display :filter :parse :routes]
    (when-let [f (get w k)]
      (unless (callable? f)
        (errorf "admin widget %q: %q must be a function, got %q"
                (get w :name :anonymous) k f))))
  # :encoding is how a widget says its control cannot ride a urlencoded
  # form: form-page flips the <form> to multipart when any resolved
  # widget declares it, and `submitted` hands such a widget's :parse
  # the request even when (req :form) never saw the field (ADR-0039 §6)
  (when-let [enc (get w :encoding)]
    (unless (= :multipart enc)
      (errorf "admin widget %q: :encoding must be :multipart, got %q"
              (get w :name :anonymous) enc)))
  (freeze (merge {:name :anonymous :priority 100} w)))

# -- the default text projection -----------------------------------------

(defn text-of
  ``What a value looks like when nobody said otherwise. `nil` is drawn
  as an em dash rather than as an empty cell: a column that is blank
  for every row and a column that is missing look identical, and only
  one of them is a bug.``
  [v]
  (cond
    (nil? v) "—"
    (boolean? v) (if v "yes" "no")
    (keyword? v) (string v)
    (bytes? v) (string v)
    (number? v) (string v)
    (string/format "%q" v)))

(defn- truncate [s n]
  (def str (string s))
  (if (<= (length str) n) str (string (string/slice str 0 n) "…")))

# -- the fallback: html/form ---------------------------------------------

(defn- form-spec
  "The html/form control description of one field — projected by the
  module that already projects schemas into controls."
  [field]
  (def specs (form/field-specs {(field :name) (field :schema)}))
  (merge (first specs) {:label (field :label)}))

(def form-widget
  ``The widget every field falls back to: html/form's own projection of
  the schema node. It is deliberately last in the order — a field the
  schema fully describes needs nothing declared about it.``
  (normalize
    {:name :void.admin/form
     :doc "html/form's projection of the schema node: input, checkbox, select or textarea"
     :render (fn form-render [ctx]
               (def spec (form-spec (ctx :field)))
               (form/input (merge spec
                                  {:name (ctx :name)
                                   :required (and (spec :required)
                                                  (not (ctx :readonly)))}
                                  (if (ctx :readonly) {:attrs (merge (get spec :attrs {})
                                                                     {:readonly true})} {}))
                           (ctx :value)))}))

# -- the link widget: one control, three shapes --------------------------

(def link-limit-dyn
  "How many target rows still count as `few` — bound from
  [:admin :select-limit] by ./init."
  :void.admin/select-limit)

(defn target-resource
  ``The admin declaration of the entity a foreign key points at, or nil
  — the widget needs the *resource*, because that is where :search, the
  ordering and the label live. This is why an inline target has to be
  declared (often with `:mount false`): the child is described once.``
  [rel]
  (when rel
    (var out nil)
    (each rname (res/resources)
      (def d (res/lookup rname))
      (when (and (nil? out) (= (rel :entity) (get-in d [:entity :name])))
        (set out d)))
    out))

(defn label-of
  ``The human label of a row: the first of :name :title :label :email
  :slug the entity actually has, else the primary key. A picker
  showing primary keys is a picker nobody can use, and guessing is
  better than making every application say so.``
  [desc row]
  (def ent (desc :entity))
  (def pk (ent :pk))
  (var out nil)
  (each k [:name :title :label :email :slug]
    (when (and (nil? out) (get-in ent [:fields k]) (not (nil? (get row k))))
      (set out (string (get row k)))))
  (string (or out (get row pk))))

(defn- link-options
  "The target rows, when there are few enough of them to be a select."
  [target limit]
  (db/query (target :entity) {:limit (inc limit) :order-by (target :order-by)}))

(def link-widget
  ``A belongs-to drawn by one widget that picks its own shape from the
  size of the target (ADR-0029 §5): a select while the target is
  small, an autocompleting input once it is not and the target
  declares a :search, and a plain identifier otherwise. Django needs
  three settings for this; the size is known where the decision is
  made, so here it is one.``
  (normalize
    {:name :void.admin/link
     :doc "belongs-to: select, autocomplete or identifier, chosen by the size of the target"
     :priority 50
     :routes
     (fn link-routes [ctx]
       (def target (target-resource (get-in ctx [:field :rel])))
       (when (and target (not (empty? (target :search))))
         [(router/route
            :get "/complete"
            (fn complete [req]
              (def q (get-in req [:query "q"] ""))
              (def rows
                (if (empty? (string q))
                  []
                  (db/query (target :entity)
                            {:where [:or ;(seq [c :in (target :search)]
                                            [:like (keyword (get-in target [:entity :fields c :column]))
                                             (string "%" q "%")])]
                             :limit 20
                             :order-by (target :order-by)})))
              {:status 200
               :headers @{"content-type" "text/html; charset=utf-8"}
               :body (hiccup/render
                       [:datalist {:id (string "dl-" (get-in ctx [:field :name]))}
                        (seq [r :in rows]
                          [:option {:value (string (get r (get-in target [:entity :pk])))}
                           (label-of target r)])])})
            {:void.admin/widget-route true})]))
     :display
     (fn link-display [ctx]
       (def rel (get-in ctx [:field :rel]))
       (def row (ctx :row))
       (def target (target-resource rel))
       (def linked
         (when (and row rel (db/preloaded? row (rel :name)))
           (db/rel row (rel :name))))
       (cond
         (nil? (ctx :value)) (text-of nil)
         (and linked target) (label-of target linked)
         (text-of (ctx :value))))
     :render
     (fn link-render [ctx]
       (def field (ctx :field))
       (def rel (field :rel))
       (def target (target-resource rel))
       (def limit (or (dyn link-limit-dyn) 100))
       (def rows (when target (link-options target limit)))
       (cond
         (and rows (<= (length rows) limit))
         [:select {:name (ctx :name) :id (ctx :id)
                   :required (when (field :required) true)
                   :disabled (when (ctx :readonly) true)}
          [:option {:value ""} "—"]
          (seq [r :in rows
                :let [id (string (get r (get-in target [:entity :pk])))]]
            [:option {:value id
                      :selected (when (= id (string (or (ctx :value) ""))) true)}
             (label-of target r)])]

         (and target (not (empty? (target :search))))
         [:span
          [:input {:type "text" :name (ctx :name) :id (ctx :id)
                   :list (string "dl-" (field :name))
                   :autocomplete "off"
                   :readonly (when (ctx :readonly) true)
                   :value (when (not (nil? (ctx :value))) (string (ctx :value)))
                   :hx-get (string (ctx :widget-url) "/complete")
                   :hx-trigger "input changed delay:300ms"
                   :hx-target (string "#dl-" (field :name))
                   :hx-swap "outerHTML"}]
          [:datalist {:id (string "dl-" (field :name))}]]

         ((form-widget :render) ctx)))}))

# -- resolution ----------------------------------------------------------

(defn- matches? [w field]
  (or (when-let [types (get w :types)]
        (truthy? (index-of (field :type) types)))
      (when-let [m (get w :match)]
        (truthy? (m field)))))

(defn resolve
  ``The widget for one field, plus *why* it was chosen — the pair
  `void admin widgets` prints. `contribs` are the :void.admin/widget
  contributions, highest priority first.

  Order (ADR-0029 §4): the field's own :widget, a matching
  contribution, the link widget for a foreign key, html/form.``
  [desc field contribs]
  (def declared (get-in desc [:widgets (field :name)]))
  (def hit (first (filter |(matches? $ field) contribs)))
  (cond
    (keyword? declared)
    (let [w (or (first (filter |(= declared ($ :name)) contribs))
                (errorf (string "admin resource %q: field %q asks for widget %q, "
                                "which nothing contributed to :void.admin/widget "
                                "(contributed: %s)")
                        (desc :name) (field :name) declared
                        (string/join (map |(string/format "%q" ($ :name)) contribs) " ")))]
      [w :declared])

    (dictionary? declared)
    [(normalize (merge {:name (keyword "anonymous." (desc :name) "/" (field :name))} declared))
     :declared]

    (not (nil? declared))
    (errorf "admin resource %q: :widgets %q must be a widget name or a widget table, got %q"
            (desc :name) (field :name) declared)

    hit [hit :contributed]

    (field :rel) [link-widget :relation]

    [form-widget :schema]))

(defn resolve-all
  ``Every field of a resource that a widget draws — form fields, list
  columns backed by a field, filters — resolved once, at mount.
  Returns {field-name {:widget :why}}.``
  [desc contribs]
  (def sorted-contribs (sorted-by |(- (get $ :priority 100)) contribs))
  (def out @{})
  (defn add [field]
    (when (and field (nil? (get out (field :name))))
      (def [w why] (resolve desc field sorted-contribs))
      (put out (field :name) {:widget w :why why :field field})))
  (each f (desc :form-fields) (add f))
  (each c (desc :list) (add (c :field)))
  (each f (desc :filters) (add (f :field)))
  (freeze out))

# -- calling a widget ----------------------------------------------------

(defn render
  "The form control for a field, through its resolved widget."
  [entry ctx]
  (((entry :widget) :render) (merge {:field (entry :field) :readonly false} ctx)))

(defn display
  ``The list cell / detail row for a field. Falls back to the text
  projection, truncated for a list — a body column must not turn one
  row into a page.``
  [entry ctx]
  (def w (entry :widget))
  (def full (merge {:field (entry :field)} ctx))
  (if-let [f (get w :display)]
    (f full)
    (let [t (text-of (full :value))]
      (if (= :list (full :mode)) (truncate t 80) t))))

(defn filter-control
  "The filter-panel control for a field, when its widget has one."
  [entry ctx]
  (when-let [f (get-in entry [:widget :filter])]
    (f (merge {:field (entry :field) :mode :filter} ctx))))

(def field-error-key
  ``What a widget's `:parse` throws to refuse a submitted value: a
  refusal is not a panic, and it is not a 500 either — the operator
  chose a file of the wrong type, and what they need is that sentence
  next to the field they chose it in.``
  :void.admin/field-error)

(defn refuse!
  ``Refuse a submitted value from inside a widget's `:parse`. The
  message lands on the field, the form re-renders with a 422, and
  nothing else about the submission is lost — which is what separates
  "you chose a .svg" from an exception (ADR-0029 §4, ADR-0039 §6).``
  [message]
  (error {field-error-key (string message)}))

(defn field-error
  "The message of a widget refusal, or nil when the error is anything
  else — anything else is a bug and stays one."
  [err]
  (when (dictionary? err) (get err field-error-key)))

(defn parse
  "One submitted string -> the domain value, when the widget says how.
  Without a :parse the value goes through schema-layer coercion, which
  is where type conversion belongs."
  [entry raw ctx]
  (if-let [f (get-in entry [:widget :parse])]
    (f raw (merge {:field (entry :field)} ctx))
    raw))

(defn multipart?
  ``Does any of these resolved entries draw a control that cannot ride
  a urlencoded body? The enctype of a form is a consequence of the
  widgets on it: a file input in a form that forgot the attribute
  submits its filename and drops the file, silently (ADR-0039 §6).``
  [entries]
  (truthy? (some |(= :multipart (get-in $ [:widget :encoding])) (or entries []))))

(defn assets
  "The {:style :script} of every distinct widget a page used — glued
  into the layout once per widget name, not once per control."
  [entries]
  (def seen @{})
  (def out @[])
  (each name (sorted (keys entries))
    (def w (get-in entries [name :widget]))
    (when-let [a (get w :assets)]
      (unless (in seen (w :name))
        (put seen (w :name) true)
        (array/push out [(w :name) a]))))
  out)
