### void/admin/action — the handlers behind the routes (ADR-0029 §2,
### §3, §5, §7).
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
### `:scope` costs one policy call, not one extra query (§3).
###
### **A change is announced, never written.** `:void.admin/changed`
### carries {:resource :action :id :before :after :subject}; who keeps
### it — a bus consumer, a log sink, nobody — is not this plugin's
### business, and no migration ships with it (§8, ADR-0012).

(import void/core/hooks :as hooks)
(import void/core/schema :as schema)
(import void/authz :as authz)
(import void/db :as db)
(import void/db/entity :as entity)
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx :as htmx)
(import void/http/ring :as ring)
(import void/http/errors :as errors)
(import ./context :as ctx)
(import ./query :as q)
(import ./resource :as res)
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

(defn- subject-of [req]
  # the identity is read by the name void/auth publishes it under, the
  # way void/authz reads it — the admin gains no edge on void/auth for it
  (def id (dyn authz/identity-dyn))
  (when (dictionary? id)
    (or (get id :subject) (get id :id) (get id :email))))

(defn snapshot-of
  "An instance's own columns as a frozen struct — what :before and
  :after of an announcement carry, with the prototype left out."
  [row]
  (when row (freeze (tabseq [[k v] :pairs row] k v))))

(defn announce!
  "Publish the fact that a row changed. Handlers call this; nothing
  here writes it down."
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

(defn- page
  ``A full admin page: the configured frame, and the widget resolution
  of this resource in the render context — that is where the layout
  finds the `:assets` it has to glue in once.``
  [req content &opt rname opts]
  (html/page content
             (merge {:layout (view/frame)
                     :context {:void.admin/widgets (if rname (ctx/widget-entries rname) {})}}
                    (or opts {}))))

(defn- partial? [req]
  (and (htmx/request? req) (not (htmx/history-restore? req))))

(defn- see-other [url]
  (ring/response 303 nil @{"location" url}))

(defn- redirect-back [req url]
  ``After a write: htmx gets an HX-Redirect (it will not follow a 303
  into a swap target), a browser gets the 303 it expects.``
  (if (htmx/request? req)
    (htmx/redirect (ring/response 204 nil @{}) url)
    (see-other url)))

# -- loading -------------------------------------------------------------

(defn load-row!
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
  "The `:void.authz/resource` of every single-row route."
  [desc]
  (fn admin-resource [req] (load-row! desc req)))

(defn- row! [desc req]
  (or (load-row! desc req) (errors/abort 404)))

# -- values --------------------------------------------------------------

(defn- submitted
  ``The form, keywordized, with each widget's `:parse` applied and the
  fields the declaration froze as read-only removed. A read-only field
  is not merely not drawn: a POST that names it is a POST that must
  not reach `save!`.

  A widget whose `:encoding` is `:multipart` is asked even when the
  field is absent from `(req :form)`, because that is where its value
  always is — the parsing middleware folds only the *non-file* parts
  into the form (ADR-0039 §6). Such a widget answering nil means "no
  file was chosen", and the field stays out of the update rather than
  overwriting what is stored with nothing.

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

(defn- checked [desc values]
  (schema/check (desc :form-schema) values {:coerce true}))

(defn with-defaults
  ``The attributes of a create, plus the columns the declaration says
  the server fills: a created-at, an owner, a tenant. They are not form
  fields — nobody types a timestamp — and they are not entity callbacks
  either, because entities have none (ADR-0009). A value already
  submitted is never overwritten by one.``
  [desc req values]
  (def out (merge (table) values))
  (eachp [k f] (desc :defaults)
    (when (nil? (get out k))
      (put out k (f req))))
  out)

# -- index ---------------------------------------------------------------

(defn index [desc]
  (fn admin-index [req]
    (def st (q/state desc req {:per-page (ctx/setting :per-page 25)}))
    (def rows (q/rows desc req st))
    (def total (q/total desc req st))
    (if (partial? req)
      (html/fragment (view/rows-fragment desc rows st total))
      (page req (view/list-page desc rows st total)
            (desc :name)))))

# -- new / create --------------------------------------------------------

(defn new [desc]
  (fn admin-new [req]
    (page req (view/form-page desc {:values {}}) (desc :name))))

(defn create [desc]
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
        (redirect-back req (ctx/url desc (string "/" id))))
      (let [resp (page req (view/form-page desc {:values (get req :form {})
                                                :errors (result :errors)})
                       (desc :name))]
        (put resp :status 422)
        resp))))

# -- show / edit / update ------------------------------------------------

(defn- inline-blocks [desc req row]
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

(defn show [desc]
  (fn admin-show [req]
    (def row (row! desc req))
    (def history
      (when-let [h (ctx/setting :history)]
        ((h :fn) {:resource (desc :name)
                  :id (get row (get-in desc [:entity :pk]))
                  :request req})))
    (page req (view/detail-page desc row (inline-blocks desc req row) history)
          (desc :name))))

(defn edit [desc]
  (fn admin-edit [req]
    (def row (row! desc req))
    (page req (view/form-page desc {:row row :values row})
          (desc :name))))

(defn- version-conflict? [err]
  (and (string? (string err)) (string/find "modified concurrently" (string err))))

(defn update [desc]
  (fn admin-update [req]
    (def row (row! desc req))
    (def before (snapshot-of row))
    (def [values refused] (submitted desc req))
    (def checked-result (checked desc values))
    (def result (merge checked-result
                       {:errors [;refused ;(checked-result :errors)]}))
    (defn invalid [errors extra]
      (def resp (page req (view/form-page desc (merge {:row row
                                                       :values (get req :form {})
                                                       :errors errors}
                                                      extra))
                      (desc :name)))
      (put resp :status 422)
      resp)
    (if (not (empty? (result :errors)))
      (invalid (result :errors) {})
      (do
        (def vfield (get-in desc [:entity :version]))
        # the version the form carried is what `save!` must diff against
        (when vfield
          (when-let [sent (get-in req [:form (string vfield)])]
            (def coerced (q/coerce (res/field-descriptor (desc :entity) vfield) sent))
            (unless (nil? coerced) (put row vfield coerced))))
        (eachp [k v] (result :value) (put row k v))
        (def [ok err] (protect (db/save! row)))
        (cond
          ok (do (announce! req desc :update (get row (get-in desc [:entity :pk]))
                            before (snapshot-of row))
                 (redirect-back req (ctx/url desc (string "/" (get row (get-in desc [:entity :pk]))))))
          (version-conflict? err)
          (invalid []
                   {:row (db/find (desc :entity) (get before (get-in desc [:entity :pk])))
                    :conflict (string "Somebody else saved this row while you were editing it. "
                                      "The fields below are theirs — re-apply your change and save again.")})
          (error err))))))

(defn destroy [desc]
  (fn admin-destroy [req]
    (def row (row! desc req))
    (def id (get row (get-in desc [:entity :pk])))
    (def before (snapshot-of row))
    (db/delete! (desc :entity) id)
    (announce! req desc :destroy id before nil)
    (redirect-back req (ctx/base desc))))

# -- one cell ------------------------------------------------------------

(defn- list-column
  "The list column of a field — an :editable field is always one, since
  a cell that is not in the list has nowhere to be edited."
  [desc fname]
  (or (first (filter |(= fname ($ :name)) (desc :list)))
      {:name fname :label (string fname)}))

(defn cell [desc]
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
        (db/save! row)
        (announce! req desc :update (get row (get-in desc [:entity :pk]))
                   before (snapshot-of row))
        (if (htmx/request? req)
          (html/fragment (view/cell desc row (list-column desc fname) true))
          (redirect-back req (ctx/base desc))))
      (do
        (def resp
          (if (htmx/request? req)
            (html/fragment [:td {:class "field-invalid"}
                            (string/join (map schema/error-str (result :errors)) "; ")])
            (redirect-back req (ctx/base desc))))
        (if (dictionary? resp) (do (put resp :status 422) resp) resp)))))

# -- inlines -------------------------------------------------------------

(defn- ensure-child!
  ``The third policy an inline route enforces. The gate and the
  parent's `:show` are on the route; the child's own action policy is
  enforced here, because it decides about the *child* — an inline that
  ran on the parent's authority would be a way around authorization,
  and half the value of TabularInline would be a hole (ADR-0029 §5).``
  [child action row]
  (authz/ensure! (res/policy-name (child :name) action)
                 {:resource row :action action}))

(defn- inline-of [desc req]
  (def iname (keyword (get-in req [:params :rel])))
  (def inline (or (get-in desc [:inlines iname]) (errors/abort 404)))
  (def child (or (res/lookup (inline :resource))
                 (errorf (string "admin resource %q: inline %q points at resource %q, "
                                 "which is not declared — an inline needs its target's "
                                 "own declaration so the child's fields and policies "
                                 "exist exactly once (ADR-0029 §5)")
                         (desc :name) iname (inline :resource))))
  [inline child])

(defn- inline-rows [desc req row inline child]
  (db/query (child :entity)
            {:where [:= (keyword (get-in child [:entity :fields (get-in inline [:rel :key]) :column]))
                     (get row (get-in desc [:entity :pk]))]
             :order-by (or (get inline :order-by)
                           [[(keyword (get-in child [:entity :pk-column])) :asc]])
             :limit (inline :per-page)}))

(defn- inline-response [desc req row inline child errors]
  (def rows (inline-rows desc req row inline child))
  (if (htmx/request? req)
    (html/fragment (view/inline-block desc row inline child rows errors))
    (redirect-back req (ctx/url desc (string "/" (get row (get-in desc [:entity :pk])))))))

(defn inline-create [desc]
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

(defn- inline-child! [req inline child parent-id]
  (def cid (q/pk-value child (get-in req [:params :child])))
  (def found
    (db/one (child :entity)
            {:where [:and
                     [:= (keyword (get-in child [:entity :pk-column])) cid]
                     [:= (keyword (get-in child [:entity :fields (get-in inline [:rel :key]) :column]))
                      parent-id]]}))
  (or found (errors/abort 404)))

(defn inline-update [desc]
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

(defn inline-destroy [desc]
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
  ``The action a bulk URL names: :destroy, or one the resource
  declared. The action is part of the *path*, so its policy cannot be
  written on the route the way the other six are — it is enforced here
  instead, once for the page and then again per row when the rows are
  known (ADR-0029 §7).``
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

(defn bulk-confirm [desc]
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
  "One row through one action — and one policy decision per row, which
  is exactly why a big bulk belongs in a job (ADR-0029 §7)."
  [req desc action row]
  # the gate was decided once, on the route; what is decided per row is
  # the action's own policy, with the row in :resource (ADR-0029 §7)
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

(defn bulk-apply [desc]
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
        (redirect-back req (ctx/base desc))))))

(defn progress [desc]
  (fn admin-progress [req]
    (def runner (or (ctx/setting :bulk-runner) (errors/abort 404)))
    (def job-id (get-in req [:params :job]))
    (def state ((runner :progress) job-id nil))
    (html/fragment (view/progress-fragment desc job-id state))))

# -- the admin's own pages -----------------------------------------------

(defn dashboard [req]
  (def widgets
    (seq [w :in (ctx/setting :dashboard [])]
      {:label (get w :label (string (w :name))) :render (fn [] ((w :render) req))}))
  (html/page (view/dashboard widgets)
             {:layout (view/frame)
              :context {:void.admin/widgets {}}}))
