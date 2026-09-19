### void/admin/action — the handlers behind the routes.
###
### Every one of these is an ordinary handler on an ordinary route, so
### the transaction is declared in metadata (`:void.db/txn`), the
### policies are enforced by void/authz-http before the handler runs,
### and the CSRF token is checked by void/security. Nothing here knows
### about any of that, which is the point of "an action is a route".
###
### **The row is loaded once and shown to its policy.** The route's
### `:void.authz/resource` calls the same loader the handler calls, and
### the loader memoizes on the request — the second echelon behind
### `:scope` costs one policy call, not one extra query.
###
### **A change is announced, never written.** `:void.admin/changed`
### carries {:resource :action :id :before :after :subject}; who keeps it
### — a bus consumer, a log sink, nobody — is not this plugin's business,
### and no migration ships with it.

(import void/core/hooks :as hooks)
(import void/core/schema :as schema)
(import void/authz :as authz)
(import void/db :as db)
(import void/db/entity :as entity)
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx :as htmx)
(import void/http/errors :as errors)
(import ./context :as ctx)
(import ./query :as q)
(import ./resource :as res)
(import ./text :as text)
(import ./view :as view)
(import ./widget :as widget)

(def changed-hook
  "The core hook every change announces itself through."
  :void.admin/changed)

(def row-key
  "Where the loaded row is memoized on the request — so the policy and
  the handler read one query."
  :void.admin/row)

# -- announcing ----------------------------------------------------------

(defn- subject-of
  {:params [HttpRequest?]
   :ret :any}
  ``The identity of the request, read by the same name void/authz
  reads it under — the admin gains no edge on void/auth for it. `req`
  is unused (the identity rides the dyn, not the request) and nil on
  the one caller that has no request at all: the bulk job.``
  [req]
  # the identity is read by the name void/auth publishes it under, the
  # way void/authz reads it — the admin gains no edge on void/auth for it
  (def id (dyn authz/identity-dyn))
  (when (dictionary? id)
    (or (get id :subject) (get id :id) (get id :email))))

(defn snapshot-of
  {:params [(or @{:any :any} :nil)] :ret (or {:any :any} :nil)}
  "An instance's own columns as a frozen struct — what :before and
  :after of an announcement carry, with the prototype left out."
  [row]
  (when row (freeze (tabseq [[k v] :pairs row] k v))))

(defn announce!
  {:params [HttpRequest?
            {:name :keyword & r} :keyword :any (or {:any :any} :nil) (or {:any :any} :nil)]
   :ret :nil}
  ``Publish the fact that a row changed. Handlers call this; nothing
  here writes it down. `req` may be nil — the bulk job announces
  outside any request.``
  [req desc action id before after]
  (when-let [reg (ctx/setting :hooks)]
    (def fact {:resource (desc :name) :action action :id id
               :before before :after after
               :subject (subject-of req)
               :at (os/time)})
    (each e (hooks/handlers reg changed-hook)
      (protect ((e :fn) fact))))
  nil)

# -- responses -----------------------------------------------------------

(defn page
  {:params [HttpRequest
            :any :keyword?
            (or {:status :number? :headers (or {:any :any} :nil)
                :context (or {:any :any} :nil) :engine :keyword?
                :title :any :head :any :partial :any & r}
               :nil)]
   :ret HtmlView
   :throws [:string]}
  ``A full admin page: the configured frame, and the widget resolution
  of this resource in the render context — which is what a replacement
  `:void.admin/layout` reads to draw anything of its own. The widgets'
  `:assets` are not in it: they are served as one file per kind, from
  the admin's own prefix (./view). A `:void.admin/page` answers through
  this too, so a contributed section is framed by the same layout as
  the seven conventional actions.``
  [req content &opt rname opts]
  (html/page content
             (merge {:layout (view/frame)
                     :context {:void.admin/widgets (if rname (ctx/widget-entries rname) {})}}
                    (or opts {}))))


# -- loading -------------------------------------------------------------

(defn load-row!
  {:params [{:scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}
            HttpRequest]
   :ret (or @{:any :any} :nil)
   :throws [:string]}
  ``The row this request is about, inside the scope, memoized on the
  request. Returns nil when it does not exist or is not this
  subject's — deliberately the same answer.``
  [desc req]
  (if (in req row-key)
    (get req row-key)
    (let [r (q/find-scoped desc req (get-in req [:params :id]))]
      (put req row-key r)
      r)))

(defn row-loader
  {:params [{:scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}]
   :ret (fn [HttpRequest]
          (or @{:any :any} :nil))}
  "The `:void.authz/resource` of every single-row route."
  [desc]
  (fn admin-resource [req] (load-row! desc req)))

(defn- row!
  {:params [{:scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}
            HttpRequest]
   :ret @{:any :any}
   :throws [:string VoidError]}
  "The loaded row, or the request ends in a 404 — what every
  single-row handler wants and does not want to spell out twice."
  [desc req]
  (or (load-row! desc req) (errors/abort 404)))

# -- values --------------------------------------------------------------

(defn- submitted
  {:params [{:name :keyword :readonly [:keyword] :form-fields [{:name :keyword & r}] & r}
            HttpRequest]
   :ret [@{:keyword :any} @[{:path [:keyword] :code :keyword :message :any}]]
   :throws [:any]}
  ``The form, keywordized, with each widget's `:parse` applied and the
  fields the declaration froze as read-only removed. A read-only field
  is not merely not drawn: a POST that names it is a POST that must
  not reach `save!`.

  A widget whose `:encoding` is `:multipart` is asked even when the
  field is absent from `(req :form)`, because that is where its value
  always is — the parsing middleware folds only the *non-file* parts
  into the form. Such a widget answering nil means "no file was chosen",
  and the field stays out of the update rather than overwriting what is
  stored with nothing.

  Returns `[values errors]`: a widget may refuse what was submitted
  (`widget/refuse!`), and a refusal is a message on its field, in the
  same shape `schema/check` produces — so the form re-renders with it
  where the operator can read it, rather than as a 500 or as a status
  line with no sentence in it.``
  [desc req]
  (def raw (form/params (get req :form {})))
  (def readonly (tabseq [k :in (desc :readonly)] k true))
  (def out @{})
  (def errors @[])
  (each fd (desc :form-fields)
    (def k (fd :name))
    (unless (in readonly k)
      (def entry (ctx/widget-entry (desc :name) k))
      (def own-body (widget/multipart? [entry]))
      (when (or (in raw k) own-body)
        (def [ok value]
          (if entry
            (protect (widget/parse entry (get raw k) {:resource desc :request req}))
            [true (get raw k)]))
        (cond
          ok (unless (and own-body (nil? value))
               (put out k value))
          (widget/field-error value)
          (array/push errors {:path [k] :code :void.admin/widget
                              :message (widget/field-error value)})
          (error value)))))
  [out errors])

(defn- checked
  {:params [{:form-schema SchemaNode & r} :any]
   :ret {:value :any :errors [:any]} :throws [:string]}
  "The submitted values against the resource's form schema, coerced."
  [desc values]
  (schema/check (desc :form-schema) values {:coerce true}))

(defn writable
  {:params [{:readonly [:keyword] :form-fields [{:name :keyword & r}] & r} {:keyword :any}]
   :ret @{:keyword :any}}
  ``The values a caller may actually write: the fields the form
  declares, minus the ones it froze as read-only. The guard is here and
  not in each caller because both callers are writers — the form
  filters read-only fields before it parses them, and the agent's
  `update` tool, whose arguments are not a form, had no filter at
  all.``
  [desc values]
  (def readonly (tabseq [k :in (desc :readonly)] k true))
  (def fields (tabseq [fd :in (desc :form-fields)] (fd :name) true))
  (tabseq [[k v] :pairs values
           :when (and (in fields k) (not (in readonly k)))]
    k v))

(defn with-defaults
  {:params [{:defaults {:keyword :function} & r}
            HttpRequest
            {:keyword :any}]
   :ret @{:keyword :any}}
  ``The attributes of a create, plus the columns the declaration says
  the server fills: a created-at, an owner, a tenant. They are not form
  fields — nobody types a timestamp — and they are not entity callbacks
  either, because entities have none. A value already submitted is never
  overwritten by one.``
  [desc req values]
  (def out (merge (table) values))
  (eachp [k f] (desc :defaults)
    (when (nil? (get out k))
      (put out k (f req))))
  out)

# -- index ---------------------------------------------------------------

(defn index
  {:params [{:name :keyword :per-page (or :number :nil) :sortable [:keyword]
             :filters [{:field {:type :keyword
                                :node SchemaNode & r}
                        :param :string :name :keyword & r}]
             :scope (or :function :nil) :search [:keyword] :order-by :any :preload :any
             :entity {:pk-column :string :fields {:keyword {:column :string & r}} & r}
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The list handler: the resource's rows for the URL's page, sort and
  filters, with the count they are paged against."
  [desc]
  (fn admin-index [req]
    (def st (q/state desc req {:per-page (ctx/setting :per-page 25)}))
    (def rows (q/rows desc req st))
    (def total (q/total desc req st))
    (page req (view/list-page desc rows st total req) (desc :name)
          {:partial (fn [] (view/rows-fragment desc rows st total))})))

# -- new / create --------------------------------------------------------

(defn new
  {:params [{:name :keyword & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The blank-form handler."
  [desc]
  (fn admin-new [req]
    (page req (view/form-page desc {:values {} :request req}) (desc :name))))

(defn create
  {:params [{:name :keyword :readonly [:keyword] :form-fields [{:name :keyword & r}]
             :form-schema SchemaNode
             :entity {:pk :keyword & r} :path :string :defaults {:keyword :function} & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The write handler behind the new form: validated and inserted, or
  the form again with what was wrong."
  [desc]
  (fn admin-create [req]
    (def [values refused] (submitted desc req))
    (def checked-result (checked desc values))
    # a widget's refusal is an error about the submission like any
    # other, and it renders in the same place
    (def result (merge checked-result
                       {:errors [;refused ;(checked-result :errors)]}))
    (if (empty? (result :errors))
      (let [row (db/insert! (desc :entity) (with-defaults desc req (result :value)))
            id (get row (get-in desc [:entity :pk]))]
        (announce! req desc :create id nil (snapshot-of row))
        (htmx/redirect-back req (ctx/url desc (string "/" id))))
      (let [resp (page req (view/form-page desc {:values (get req :form {})
                                                :errors (result :errors)
                                                :request req})
                       (desc :name))]
        (put resp :status 422)
        resp))))

# -- show / edit / update ------------------------------------------------

(defn- inline-blocks
  {:params [{:inlines {:keyword {:resource :keyword :rel :any :order-by :any :per-page :any & r}}
             :entity {:pk :keyword & r} & r}
            :any
            @{:any :any}]
   :ret @[:any]}
  "One rendered block per declared inline whose target resource is
  actually registered — an inline pointed at an undeclared resource
  draws nothing rather than raising on every row."
  [desc req row]
  (seq [iname :in (sorted (keys (desc :inlines)))
        :let [inline (get-in desc [:inlines iname])
              child (res/lookup (inline :resource))]
        :when child]
    (def rel (inline :rel))
    (def rows (db/query (child :entity)
                        {:where [:= (keyword (get-in child [:entity :fields (rel :key) :column]))
                                 (get row (get-in desc [:entity :pk]))]
                         :order-by (or (get inline :order-by)
                                       [[(keyword (get-in child [:entity :pk-column])) :asc]])
                         :limit (inline :per-page)}))
    (view/inline-block desc row inline child rows nil)))

(defn show
  {:params [{:name :keyword :scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             :inlines {:keyword {:resource :keyword :rel :any :order-by :any :per-page :any & r}}
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The detail-page handler: the row, its inlines and its history."
  [desc]
  (fn admin-show [req]
    (def row (row! desc req))
    (def history
      (when-let [h (ctx/setting :history)]
        ((h :fn) {:resource (desc :name)
                  :id (get row (get-in desc [:entity :pk]))
                  :request req})))
    (page req (view/detail-page desc row (inline-blocks desc req row) history req)
          (desc :name))))

(defn edit
  {:params [{:name :keyword :scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The edit-form handler: the row, drawn through the same form
  `create` writes through."
  [desc]
  (fn admin-edit [req]
    (def row (row! desc req))
    (page req (view/form-page desc {:row row :values row :request req})
          (desc :name))))

(defn- version-conflict?
  {:params [:any] :ret :boolean :narrows :any}
  "Does this error's text say `save!` lost a version race?"
  [err]
  (and (string? (string err)) (string/find "modified concurrently" (string err))))

(defn update-row!
  {:params [{:entity {:pk :keyword & r} :readonly [:keyword]
             :form-fields [{:name :keyword & r}] & r}
            HttpRequest
            @{:any :any} {:keyword :any} :any?]
   :ret [(enum :ok :conflict) :any]
   :throws [:any]}
  ``Write `values` onto `row`, save it and announce it — the one write
  the form and the agent's `update` tool both go through, so the
  read-only fields, the version column, the transaction and the
  announcement are decided once and not twice.

  `version` is the value the caller read *before* it edited, and it is
  what `save!` guards by. It has to be passed rather than taken off the
  row: the row this handler loads is loaded *now*, so its own version is
  fresh by construction and guarding by it would guard by nothing. The
  form carries the version it was drawn with in a hidden field, an agent
  passes the one it read from `get`, and only then is a lost race a
  conflict somebody can read instead of a silently overwritten edit.

  A caller that has no transaction of its own gets one — the HTML route
  declares `:void.db/txn` and this is already inside it, an agent's call
  is not a route and has nothing.

  Returns `[:ok row]` or `[:conflict err]`. Anything else is a bug and
  is raised.``
  [desc req row values &opt version]
  (def pk (get-in desc [:entity :pk]))
  (def before (snapshot-of row))
  (eachp [k v] (writable desc values) (put row k v))
  (defn write
    {:ret :nil}
    "Save the row and announce the change — the one write both a
    fresh transaction and an existing one run the same way."
    []
    (db/save! row {:version version})
    (announce! req desc :update (get row pk) before (snapshot-of row)))
  (def [ok err]
    (protect (if (db/in-transaction?) (write) (db/with-tx (write)))))
  (cond
    ok [:ok row]
    (version-conflict? err) [:conflict err]
    (error err)))

(defn update
  {:params [{:name :keyword :readonly [:keyword] :form-fields [{:name :keyword & r}]
             :form-schema SchemaNode
             :path :string :scope (or :function :nil) :search [:keyword] :preload :any
             :entity {:name :keyword :pk :keyword :pk-column :string :version (or :keyword :nil)
                      :fields {:keyword DbField}
                      :schema SchemaNode & r}
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The write handler behind the edit form: validated and saved, or a
  version conflict, or the form again with what was wrong."
  [desc]
  (fn admin-update [req]
    (def row (row! desc req))
    (def before (snapshot-of row))
    (def [values refused] (submitted desc req))
    (def checked-result (checked desc values))
    (def result (merge checked-result
                       {:errors [;refused ;(checked-result :errors)]}))
    (defn invalid
      {:params [(or [:any] :nil) {:keyword :any}]
       :ret HtmlView}
      "The form again, 422, with what was wrong on it."
      [errors extra]
      (def resp (page req (view/form-page desc (merge {:row row
                                                       :values (get req :form {})
                                                       :errors errors
                                                       :request req}
                                                      extra))
                      (desc :name)))
      (put resp :status 422)
      resp)
    (if (not (empty? (result :errors)))
      (invalid (result :errors) {})
      (do
        (def vfield (get-in desc [:entity :version]))
        # the version the form carried is what `save!` must diff against
        (def sent
          (when vfield
            (when-let [raw (get-in req [:form (string vfield)])]
              (q/coerce (res/field-descriptor (desc :entity) vfield) raw))))
        (def [outcome _] (update-row! desc req row (result :value) sent))
        (if (= :conflict outcome)
          (invalid []
                   {:row (db/find (desc :entity) (get before (get-in desc [:entity :pk])))
                    :conflict (text/t :void.admin/conflict)})
          (htmx/redirect-back
            req (ctx/url desc (string "/" (get row (get-in desc [:entity :pk]))))))))))

(defn destroy
  {:params [{:name :keyword :path :string :scope (or :function :nil) :search [:keyword]
             :preload :any
             :entity DbEntity
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The delete handler: the row is loaded once, deleted, and the
  deletion is announced with what it was before it was gone."
  [desc]
  (fn admin-destroy [req]
    (def row (row! desc req))
    (def id (get row (get-in desc [:entity :pk])))
    (def before (snapshot-of row))
    (db/delete! (desc :entity) id)
    (announce! req desc :destroy id before nil)
    (htmx/redirect-back req (ctx/base desc))))

# -- one cell ------------------------------------------------------------

(defn- list-column
  {:params [{:list [{:name :keyword & r}] & r} :keyword] :ret {:name :keyword & r}}
  "The list column of a field — an :editable field is always one, since
  a cell that is not in the list has nowhere to be edited."
  [desc fname]
  (or (first (filter |(= fname ($ :name)) (desc :list)))
      {:name fname :label (string fname)}))

(defn cell
  {:params [{:name :keyword :editable [:keyword] :list [{:name :keyword & r}]
             :scope (or :function :nil) :search [:keyword] :preload :any :path :string
             :entity {:name :keyword :pk :keyword :pk-column :string
                      :schema SchemaNode
                      :fields {:keyword DbField}
                      & r}
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The one-cell write handler behind an :editable list column."
  [desc]
  (fn admin-cell [req]
    (def row (row! desc req))
    (def fname (keyword (get-in req [:params :field])))
    (unless (index-of fname (desc :editable))
      (errors/abort 404))
    (def before (snapshot-of row))
    (def entry (ctx/widget-entry (desc :name) fname))
    (def raw (get-in req [:form (string fname)]))
    (def [ok parsed]
      (if entry
        (protect (widget/parse entry raw {:resource desc :request req}))
        [true raw]))
    (unless (or ok (widget/field-error parsed)) (error parsed))
    (def result
      (if ok
        (schema/check (schema/select (get-in desc [:entity :schema]) [fname])
                      {fname parsed} {:coerce true})
        {:value {} :errors [{:path [fname] :code :void.admin/widget
                             :message (widget/field-error parsed)}]}))
    (if (empty? (result :errors))
      (do
        (put row fname (get-in result [:value fname]))
        # no :version here: a cell is read and written in the same
        # gesture, and the list page carries no version per row to send
        # back — the guard would be the one `save!` derives anyway
        (db/save! row)
        (announce! req desc :update (get row (get-in desc [:entity :pk]))
                   before (snapshot-of row))
        (if (htmx/partial-request? req)
          (html/fragment (view/cell desc row (list-column desc fname) true))
          (htmx/redirect-back req (ctx/base desc))))
      (do
        (def resp
          (if (htmx/partial-request? req)
            (html/fragment [:td {:class "field-invalid"}
                            (string/join (map schema/error-str (result :errors)) "; ")])
            (htmx/redirect-back req (ctx/base desc))))
        (if (dictionary? resp) (do (put resp :status 422) resp) resp)))))

# -- inlines -------------------------------------------------------------

(defn- ensure-child!
  {:params [{:name :keyword & r} :keyword :any] :ret :any :throws [:any]}
  ``The third policy an inline route enforces. The gate and the
  parent's `:show` are on the route; the child's own action policy is
  enforced here, because it decides about the *child* — an inline that
  ran on the parent's authority would be a way around authorization,
  and half the value of TabularInline would be a hole.``
  [child action row]
  (authz/ensure! (res/policy-name (child :name) action)
                 {:resource row :action action}))

(defn- inline-of
  {:params [{:name :keyword :inlines {:keyword {:resource :keyword & r}} & r}
            HttpRequest]
   :ret [{:resource :keyword & r} {:name :keyword & r}]
   :throws [:any :string]}
  "The inline the URL names and the resource it points at, or a 404 /
  a refusal naming the undeclared target."
  [desc req]
  (def iname (keyword (get-in req [:params :rel])))
  (def inline (or (get-in desc [:inlines iname]) (errors/abort 404)))
  (def child (or (res/lookup (inline :resource))
                 (errorf (string "admin resource %q: inline %q points at resource %q, "
                                 "which is not declared — an inline needs its target's "
                                 "own declaration so the child's fields and policies "
                                 "exist exactly once")
                         (desc :name) iname (inline :resource))))
  [inline child])

(defn- inline-rows
  {:params [{:entity {:pk :keyword & r} & r} :any @{:any :any}
            {:rel {:key :keyword & r} :order-by :any :per-page :any & r}
            {:entity {:pk-column :string :fields {:keyword {:column :string & r}} & r} & r}]
   :ret @[@{:any :any}]}
  "The child rows an inline draws for one parent row."
  [desc req row inline child]
  (db/query (child :entity)
            {:where [:= (keyword (get-in child [:entity :fields (get-in inline [:rel :key]) :column]))
                     (get row (get-in desc [:entity :pk]))]
             :order-by (or (get inline :order-by)
                           [[(keyword (get-in child [:entity :pk-column])) :asc]])
             :limit (inline :per-page)}))

(defn- inline-response
  {:params [{:entity {:pk :keyword & r} & r}
            HttpRequest
            @{:any :any}
            {:rel {:key :keyword & r} :order-by :any :per-page :any & r}
            {:entity {:pk :keyword :pk-column :string
                      :fields {:keyword {:column :string & r}} & r} & r}
            (or [:any] :nil)]
   :ret :any}
  "After an inline write: the child block alone under htmx, else the
  whole page again."
  [desc req row inline child errors]
  (def rows (inline-rows desc req row inline child))
  (if (htmx/partial-request? req)
    (html/fragment (view/inline-block desc row inline child rows errors))
    (htmx/redirect-back req (ctx/url desc (string "/" (get row (get-in desc [:entity :pk])))))))

(defn inline-create
  {:params [{:name :keyword :inlines {:keyword {:resource :keyword & r}}
             :scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The add-row handler behind an inline: the child written under its
  own policy, the parent's link taken from the URL and never the
  form."
  [desc]
  (fn admin-inline-create [req]
    (def row (row! desc req))
    (def [inline child] (inline-of desc req))
    (ensure-child! child :create nil)
    (def [values refused] (submitted child req))
    # the link to the parent comes from the URL, never from the form
    (def fk (get-in inline [:rel :key]))
    (def checked-result (schema/check (child :form-schema) values {:coerce true}))
    (def result (merge checked-result
                       {:errors [;refused ;(checked-result :errors)]}))
    (if (empty? (result :errors))
      (do
        (def created
          (db/insert! (child :entity)
                      (merge (with-defaults child req (result :value))
                             {fk (get row (get-in desc [:entity :pk]))})))
        (announce! req child :create (get created (get-in child [:entity :pk]))
                   nil (snapshot-of created))
        (inline-response desc req row inline child nil))
      (inline-response desc req row inline child (result :errors)))))

(defn- inline-child!
  {:params [HttpRequest
            {:rel {:key :keyword & r} & r}
            {:entity DbEntity
             & r}
            :any]
   :ret @{:any :any}
   :throws [:string VoidError]}
  "The one child row an inline write is about, inside the parent — or
  a 404, the same answer as a forged parent link."
  [req inline child parent-id]
  (def cid (q/pk-value child (get-in req [:params :child])))
  (def found
    (db/one (child :entity)
            {:where [:and
                     [:= (keyword (get-in child [:entity :pk-column])) cid]
                     [:= (keyword (get-in child [:entity :fields (get-in inline [:rel :key]) :column]))
                      parent-id]]}))
  (or found (errors/abort 404)))

(defn inline-update
  {:params [{:name :keyword :inlines {:keyword {:resource :keyword & r}}
             :scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The write handler behind an inline row's own edit."
  [desc]
  (fn admin-inline-update [req]
    (def row (row! desc req))
    (def [inline child] (inline-of desc req))
    (def parent-id (get row (get-in desc [:entity :pk])))
    (def c (inline-child! req inline child parent-id))
    (ensure-child! child :update c)
    (def before (snapshot-of c))
    (def [values refused] (submitted child req))
    (def checked-result (schema/check (child :form-schema) values {:coerce true}))
    (def result (merge checked-result
                       {:errors [;refused ;(checked-result :errors)]}))
    (if (empty? (result :errors))
      (do
        (eachp [k v] (result :value) (put c k v))
        (db/save! c)
        (announce! req child :update (get c (get-in child [:entity :pk]))
                   before (snapshot-of c))
        (inline-response desc req row inline child nil))
      (inline-response desc req row inline child (result :errors)))))

(defn inline-destroy
  {:params [{:name :keyword :inlines {:keyword {:resource :keyword & r}}
             :scope (or :function :nil) :search [:keyword] :preload :any
             :entity DbEntity
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The delete handler behind an inline row."
  [desc]
  (fn admin-inline-destroy [req]
    (def row (row! desc req))
    (def [inline child] (inline-of desc req))
    (def parent-id (get row (get-in desc [:entity :pk])))
    (def c (inline-child! req inline child parent-id))
    (ensure-child! child :destroy c)
    (def cid (get c (get-in child [:entity :pk])))
    (db/delete! (child :entity) cid)
    (announce! req child :destroy cid (snapshot-of c) nil)
    (inline-response desc req row inline child nil)))

# -- bulk ----------------------------------------------------------------

(defn action-of
  {:params [{:name :keyword :action-set {:keyword :boolean}
             :custom-actions {:keyword {:name :keyword :label :any & r}} & r}
            :any :keyword]
   :ret {:name :keyword :label :any & r}
   :throws [:any VoidError]}
  ``The action a bulk URL names: :destroy, or one the resource
  declared. The action is part of the *path*, so its policy cannot be
  written on the route the way the other six are — it is enforced here
  instead, once for the page and then again per row when the rows are
  known.``
  [desc req name]
  (def action
    (cond
      (= :destroy name)
      (do (unless (in (desc :action-set) :destroy) (errors/abort 404))
          {:name :destroy :label "Delete" :danger true})
      (or (get-in desc [:custom-actions name]) (errors/abort 404))))
  (authz/ensure! (res/policy-name (desc :name) (action :name))
                 {:action (action :name)})
  action)

(def cascade-cap
  ``How many parents a confirmation page counts children for. A page
  that says what a delete takes with it must not become the slowest
  query in the application; past this many parents it says "at least",
  which is the honest reading of a partial count.``
  1000)

(defn- cascade-counts
  {:params [{:preload :any
             :entity {:pk :keyword :pk-column :string
                      :rels {:keyword {:kind :keyword :entity :keyword :key :keyword & r}} & r}
             & r}
            {:where (or :tuple :nil) & r}]
   :ret @[[:string :number :boolean]]}
  "What a delete takes with it: one count per has-many, so the page
  says it out loud before anybody presses the button. Each entry is
  [label count capped?]."
  [desc sel]
  (def ent (desc :entity))
  (def out @[])
  (def parents (q/selected-rows desc sel (inc cascade-cap)))
  (def capped (> (length parents) cascade-cap))
  (def ids (tuple ;(map |(get $ (ent :pk)) (take cascade-cap parents))))
  (unless (empty? ids)
    (eachp [rname rel] (ent :rels)
      (when (= :has-many (rel :kind))
        (def target (entity/resolve (rel :entity)))
        (def n (db/count target
                         {:where [:in (keyword (get-in target [:fields (rel :key) :column]))
                                  ids]}))
        (when (pos? n) (array/push out [(string rname) n capped])))))
  (sorted-by first out))

(defn bulk-confirm
  {:params [{:name :keyword :action-set {:keyword :boolean}
             :custom-actions {:keyword {:name :keyword :label :any & r}}
             :per-page (or :number :nil) :sortable [:keyword]
             :filters [{:field {:type :keyword
                                :node SchemaNode & r}
                        :param :string :name :keyword & r}]
             :scope (or :function :nil) :search [:keyword] :preload :any
             :entity {:pk :keyword :pk-column :string
                      :fields {:keyword DbField}
                      :schema SchemaNode
                      :rels {:keyword {:kind :keyword :entity :keyword :key :keyword & r}} & r}
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The confirmation page a bulk goes through: what it will do, how
  many rows, a sample, and — for a destroy — what goes with them."
  [desc]
  (fn admin-bulk-confirm [req]
    (def action (action-of desc req (keyword (get-in req [:params :action]))))
    (def st (q/state desc req {:per-page (ctx/setting :per-page 25)}))
    (def sel (q/selection desc req st))
    (def total (q/selected-count desc sel))
    (def sample (q/selected-rows desc sel 5))
    (page req
          (view/confirm-page desc action
                             {:total total
                              :sample sample
                              :all (sel :all)
                              :ids (get sel :ids [])
                              :cascade (when (= :destroy (action :name))
                                         (cascade-counts desc sel))
                              :carry (seq [[k v] :pairs (get req :query {})
                                           :when (and (not= k "ids") (not= k "all")
                                                      (not (indexed? v)))]
                                       [k v])})
          (desc :name))))

(defn- apply-one!
  {:params [HttpRequest
            {:name :keyword :entity {:pk :keyword & r} & r}
            {:name :keyword :apply (or :function :nil) & r}
            @{:any :any}]
   :ret :nil :throws [:any]}
  "One row through one action — and one policy decision per row, which
  is exactly why a big bulk belongs in a job."
  [req desc action row]
  # the gate was decided once, on the route; what is decided per row is
  # the action's own policy, with the row in :resource
  (authz/ensure! (res/policy-name (desc :name) (action :name))
                 {:resource row :action (action :name)})
  (def id (get row (get-in desc [:entity :pk])))
  (def before (snapshot-of row))
  (if (= :destroy (action :name))
    (do (db/delete! (desc :entity) id)
        (announce! req desc :destroy id before nil))
    (do ((action :apply) row req)
        (announce! req desc (action :name) id before
                   (snapshot-of (db/find (desc :entity) id))))))

(defn bulk-apply
  {:params [{:name :keyword :action-set {:keyword :boolean}
             :custom-actions {:keyword {:name :keyword :label :any & r}}
             :per-page (or :number :nil) :sortable [:keyword]
             :filters [{:field {:type :keyword
                                :node SchemaNode & r}
                        :param :string :name :keyword & r}]
             :scope (or :function :nil) :search [:keyword] :preload :any :path :string
             :entity {:pk :keyword :pk-column :string
                      :fields {:keyword DbField}
                      :schema SchemaNode & r}
             & r}]
   :ret (fn [HttpRequest]
          :any)}
  "The bulk itself: run inline in batches, or handed to the bulk
  runner when the action declares :job or the selection is too big."
  [desc]
  (fn admin-bulk-apply [req]
    (def action (action-of desc req (keyword (get-in req [:params :action]))))
    (def st (q/state desc req {:per-page (ctx/setting :per-page 25)}))
    (def sel (q/selection desc req st))
    (def total (q/selected-count desc sel))
    (def limit (ctx/setting :inline-limit 500))
    (def runner (ctx/setting :bulk-runner))
    (cond
      (and (or (get action :job) (> total limit)) runner)
      (let [job-id ((runner :enqueue) {:resource (desc :name)
                                       :action (action :name)
                                       :selection sel
                                       :request req})]
        (page req (view/progress-page desc action job-id
                                      ((runner :progress) job-id action))
              (desc :name)))

      (and (or (get action :job) (> total limit)) (nil? runner))
      (errorf (string "admin resource %q: action %q would touch %d rows, which is over "
                      "[:admin :bulk :inline-limit] (%d) — compose :void/admin-jobs so it "
                      "can run as a job, raise the limit, or narrow the selection")
              (desc :name) (action :name) total limit)

      (do
        (var after nil)
        (forever
          (def batch (q/selected-rows desc sel 200 after))
          (when (empty? batch) (break))
          (each r batch
            (apply-one! req desc action r)
            (set after (get r (get-in desc [:entity :pk]))))) 
        (htmx/redirect-back req (ctx/base desc))))))

(defn progress
  {:params [:any]
   :ret (fn [HttpRequest]
          :any)
   :throws [VoidError]}
  "The progress-fragment handler a page polls while a bulk job runs."
  [desc]
  (fn admin-progress [req]
    (def runner (or (ctx/setting :bulk-runner) (errors/abort 404)))
    (def job-id (get-in req [:params :job]))
    (def state ((runner :progress) job-id nil))
    (html/fragment (view/progress-fragment desc job-id state))))

# -- the admin's own pages -----------------------------------------------

(defn dashboard
  {:params [HttpRequest]
   :ret HtmlView
   :throws [:string]}
  "The admin's front page: at-a-glance tiles, one per
  :void.admin/dashboard-widget contribution."
  [req]
  (def widgets
    (seq [w :in (ctx/setting :dashboard [])]
      # the label goes through as declared — a keyword is a translation
      # key and ./view resolves it where it draws it
      {:label (get w :label) :name (w :name) :render (fn [] ((w :render) req))}))
  (html/page (view/dashboard widgets)
             {:layout (view/frame)
              :context {:void.admin/widgets {}}}))
