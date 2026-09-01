### void/cli/make — `void make resource NAME field:type ...`
### (SPEC.md §5.17).
###
### A resource is one declaration written into four files, and the
### point of generating them together is that they are four projections
### of the same thing: `defentity` is the schema *and* the db-mapping
### (ADR-0009), the form markup and its validation are `schema/select`
### over that same node (ADR-0008), the routes carry the names the
### policies will want, and the migration creates exactly the columns
### the entity names. Written by hand, those four drift; written from
### one spec, they cannot — and the generated suite checks that they
### still agree after the first edit.
###
### **Templates are data.** The built-in set is a tuple of
### `{:key :path :render}` entries whose `:render` is a pure
### `(fn [spec] string)`, exactly as in ./new. A project overrides one
### by dropping a Janet module at `templates/resource/<key>.janet` that
### defines `render` (and, if the file should land elsewhere, `path`).
### There is deliberately no second templating language: a project that
### wants its own layout writes Janet, which is what it is going to
### edit the output in anyway.
###
### **Nothing existing is edited.** `make` writes new files, refuses to
### clobber (`--force` to insist) and *prints* the one line to add to
### `:plugins` rather than reaching into main.janet. A generator that
### rewrites hand-edited code is a generator nobody dares run twice.
###
### `--dry-run` prints what would be written, to stdout, so it composes
### with a pager and a diff. Every question the interactive pass asks
### has a flag and a default, so the same command runs in CI (./prompt).

(import ./prompt)
(import ./template)

# -- naming --------------------------------------------------------------

(def- vowels "aeiou")

(defn plural
  ``The plural of an English noun, by the three rules that cover the
  cases a table name is usually in: "-s -x -z -ch -sh" take "es", a
  consonant plus "y" becomes "ies", everything else takes "s". It is
  wrong about "person" and about half of what a real domain is called,
  which is why `--plural` and `--table` exist and why the value is
  printed before anything is written.``
  [word]
  (def w (string word))
  (cond
    (empty? w) w
    (or (string/has-suffix? "s" w) (string/has-suffix? "x" w)
        (string/has-suffix? "z" w) (string/has-suffix? "ch" w)
        (string/has-suffix? "sh" w))
    (string w "es")
    (and (string/has-suffix? "y" w)
         (> (length w) 1)
         (not (string/find (string/from-bytes (w (- (length w) 2))) vowels)))
    (string (string/slice w 0 -2) "ies")
    (string w "s")))

(defn kebab
  ``Kebab spelling of a name: "BlogPost" and "blog_post" both become
  "blog-post". The CLI accepts whichever spelling the user has in mind
  and normalizes once, here.``
  [name]
  (def s (string name))
  (def out @"")
  (for i 0 (length s)
    (def c (s i))
    (cond
      (and (>= c 65) (<= c 90))
      (do (when (and (pos? i) (not= 45 (last out)) (not= 95 (s (dec i))))
            (buffer/push-byte out 45))
          (buffer/push-byte out (+ c 32)))
      (= c 95) (buffer/push-byte out 45)
      (buffer/push-byte out c)))
  (string out))

(defn pascal
  ``Entity spelling of a name: "blog-post" -> "BlogPost". This is the
  binding the generated module defines and the keyword the schema
  registry knows it by, so it has to round-trip with `kebab`.``
  [name]
  (string/join
    (map (fn [part]
           (if (empty? part)
             part
             (string (string/ascii-upper (string/slice part 0 1))
                     (string/slice part 1))))
         (string/split "-" (kebab name)))))

(defn snake
  "Column and table spelling: \"blog-post\" -> \"blog_post\"."
  [name]
  (string/replace-all "-" "_" (kebab name)))

(defn- title [name]
  (def w (kebab name))
  (string/join
    (map |(if (empty? $) $
            (string (string/ascii-upper (string/slice $ 0 1)) (string/slice $ 1)))
         (string/split "-" w))
    " "))

# -- field types ---------------------------------------------------------
#
# One row per type, and every column of the row is a projection the
# generator needs: the schema node the entity declares, the DDL column
# the migration creates, the form control the markup uses and a value
# the suite can validate. They live together because a type added in
# one of them and forgotten in another is exactly the drift this
# command exists to remove.

(def field-types
  ``The types `name:type` accepts, in the order the interactive picker
  offers them. One row per type, and every key of the row is a
  projection some generated file needs: `:type` and `:props` are the
  schema node the entity declares, `:column` is the builder's portable
  DDL type and `:db/type` what the column actually became (the ERD
  prints it), `:control` overrides the form control the schema would
  imply, `:unique` is a constraint the migration writes, and `:sample`
  is a valid value for the generated suite.``
  [{:label "string" :value :string :doc "short text, one input"
    :column :text :db/type "text" :sample `"a name"`
    :props `{:min 1 :max 120}` :type :string}
   {:label "text" :value :text :doc "long text, a textarea"
    :column :text :db/type "text" :sample `"a longer body"`
    :props `{:min 1 :max 4000}` :type :string :control :textarea}
   {:label "int" :value :int :doc "whole number"
    :column :int :db/type "integer" :sample "42" :props nil :type :int}
   {:label "float" :value :float :doc "fractional number"
    :column :real :db/type "real" :sample "1.5" :props nil :type :number}
   {:label "bool" :value :bool :doc "true or false"
    :column :bool :db/type "boolean" :sample "true" :props nil :type :boolean}
   {:label "email" :value :email :doc "a string, format-checked and unique"
    :column :text :db/type "text" :sample `"ada@example.com"`
    :props `{:format :email :db/unique true}` :type :string :unique true}
   {:label "uuid" :value :uuid :doc "a uuid"
    :column :uuid :db/type "uuid"
    :sample `"3f2504e0-4f89-41d3-9a0c-0305e82c3301"` :props nil :type :uuid}
   {:label "date" :value :date :doc "a calendar date, as text"
    :column :date :db/type "date" :sample `"2026-01-31"` :props nil :type :string}
   {:label "datetime" :value :datetime :doc "a timestamp, as text"
    :column :timestamp :db/type "timestamp"
    :sample `"2026-01-31T09:00:00Z"` :props nil :type :string}
   {:label "ref" :value :ref :doc "belongs-to another entity (name:ref:Author)"
    :column :int :db/type "integer" :sample "1" :props nil :type :int}])

(def- type-by-value (tabseq [t :in field-types] (t :value) t))

(defn- field-type [name]
  (or (in type-by-value name)
      (errorf "unknown field type %q — one of %s"
              name (string/join (map |(string ($ :label)) field-types) ", "))))

(defn parse-field
  ``Parse one `name[:type][?]` argument into a field declaration:

      title            -> {:name :title :type :string}
      body:text        -> {:name :body :type :text}
      votes:int?       -> {:name :votes :type :int :optional? true}
      author:ref:Post  -> {:name :author-id :type :ref :entity :Post
                           :rel :author :table "posts"}

  A trailing `?` is "the column may be null", which is the only thing
  about a column a scaffolder can honestly guess wrong in a way the
  user notices immediately.``
  [arg]
  # the `?` is stripped from the whole argument first, so it means the
  # same thing wherever a reader puts it — `votes:int?` and `title?`
  # and `author:ref:Author?` are all "may be null"
  (def raw (string arg))
  (def optional? (string/has-suffix? "?" raw))
  (def parts (string/split ":" (if optional? (string/slice raw 0 -2) raw)))
  (when (or (empty? parts) (empty? (parts 0)))
    (errorf "field %q: expected name[:type], e.g. title:string" arg))
  (def name (kebab (parts 0)))
  (def tname (if (< (length parts) 2) :string (keyword (parts 1))))
  (def spec (field-type tname))
  (when (and (= :ref tname) (< (length parts) 3))
    (errorf "field %q: a ref names its entity, e.g. author:ref:Author" arg))
  (if (= :ref tname)
    (let [ent (pascal (parts 2))
          base (if (string/has-suffix? "-id" name) (string/slice name 0 -4) name)]
      {:name (keyword (string base "-id"))
       :type :ref
       :optional? optional?
       :entity (keyword ent)
       :rel (keyword base)
       :table (snake (plural (kebab ent)))})
    {:name (keyword name) :type tname :optional? optional?}))

# -- the spec ------------------------------------------------------------

(defn- timestamp []
  (def d (os/date (os/time) true))
  (string/format "%04d%02d%02d%02d%02d%02d"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn resource-spec
  ``The value every template is a pure function of:

      {:name "user" :entity "User" :plural "users" :table "users"
       :title "User" :project "demo" :plugin "demo/users"
       :dir "resources" :version "20260830120000" :fields [...]}

  Building it is the whole of the command's judgement; rendering it is
  mechanical, which is why `--dry-run` can show the result without a
  filesystem and why an override only has to be a function of this.``
  [name fields &opt opts]
  (default opts {})
  (def base (kebab name))
  # the name becomes a plugin keyword, a table name and a route
  # segment, so it is checked once, here, rather than three times in
  # three error messages nobody wrote
  (unless (peg/match '(* (range "az") (any (+ (range "az") (range "09") "-")) -1) base)
    (errorf "resource name %q must be a word (User, blog-post, BlogPost) — it becomes the plugin %s and the table"
            name (string "<project>/" (plural base))))
  (def plural-name (or (get opts :plural) (plural base)))
  (def project (get opts :project "app"))
  {:name base
   :entity (pascal base)
   :plural plural-name
   :table (or (get opts :table) (snake plural-name))
   :title (title base)
   :project project
   :plugin (string project "/" plural-name)
   :dir (get opts :dir "resources")
   :migrations-dir (get opts :migrations-dir "db/migrations")
   :test-dir (get opts :test-dir "test")
   :version (or (get opts :version) (timestamp))
   :fields (tuple ;fields)})

# -- rendering helpers ---------------------------------------------------

(defn- node-source
  "The schema node one field declares, as source text."
  [f]
  (def spec (field-type (f :type)))
  (def props
    (cond
      (= :ref (f :type)) (string/format "{:db/fk %q :db/type %q}"
                                        (f :entity) (spec :db/type))
      (nil? (spec :props)) (string/format "{:db/type %q}" (spec :db/type))
      (string (string/slice (spec :props) 0 -2)
              (string/format " :db/type %q}" (spec :db/type)))))
  (def core (string/format "[%q %s]" (spec :type) props))
  (if (f :optional?) (string/format "[:optional %s]" core) core))

(defn- column-source
  "The DDL column one field creates, as source text."
  [f]
  (def spec (field-type (f :type)))
  (def opts @[])
  (array/push opts (string/format ":null %s" (if (f :optional?) "true" "false")))
  (when (spec :unique) (array/push opts ":unique true"))
  (when (= :ref (f :type))
    (array/push opts (string/format ":refs [:%s :id] :on-delete :cascade" (f :table))))
  (string/format "[%q %q {%s}]" (f :name) (spec :column) (string/join opts " ")))

(defn- form-field-source
  "The `:fields` override of one field in the form declaration, or nil
  when the control the schema implies is already right."
  [f]
  (when-let [c (get (field-type (f :type)) :control)]
    (string/format "%q {:control %q}" (f :name) c)))

(defn- indent [n lines]
  (def pad (string/repeat " " n))
  (string/join lines (string "\n" pad)))

(defn- field-keys [spec]
  (string/join (map |(string/format "%q" ($ :name)) (spec :fields)) " "))

(defn- form-fields [spec]
  (filter identity (map form-field-source (spec :fields))))

(defn- rels [spec]
  (filter |(= :ref ($ :type)) (spec :fields)))

(defn- sample-source [spec]
  (string/join
    (map (fn [f] (string/format "%q %s" (f :name) (get (field-type (f :type)) :sample)))
         (spec :fields))
    " "))

(defn- display-field
  "The field a list row shows. The first string-ish one, because a row
  of integers is a row nobody can read; the primary key when there is
  no such field."
  [spec]
  (or (find |(index-of ($ :type) [:string :text :email]) (spec :fields))
      (first (spec :fields))))

# -- the built-in templates ----------------------------------------------
#
# The holes are filled by ./template, which `void new` uses for the
# same reason: the text of a generated file reads, here, exactly as it
# will read on disk.

(def resource-template
  "The resource module: entity, form projection, views, handlers, routes."
  ```
### {{plugin}} — the {{entity}} resource: entity, views, handlers, routes.
###
### Generated by `void make resource`. Everything below is a projection
### of the one declaration at the top: `db/defentity` is the schema
### *and* the db-mapping (ADR-0009), `schema/select` projects the form
### DTO off it instead of repeating it, `form/form` renders that
### projection and `form/check` validates against it. Rename a field in
### the entity and the form, the validation and the suite follow. The
### migration beside this file is the one thing that does not follow,
### which is why the generated suite compares the two.
###
### Handlers are registered as symbols, so redefining one in the repl —
### or saving this file with `void dev` running — is live (ADR-0002).
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/db :as db)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/errors :as errors)
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx/hx :as hx)

# -- the declaration -----------------------------------------------------

(db/defentity {{entity}}
  {:id [:int {:db/pk true :db/type "integer"}]
   {{schema-fields}}}
  :db/table "{{table}}"{{rels}})

(def {{entity}}Form
  "What the form submits — a projection of the entity, not a copy."
  (schema/select {{entity}} [{{field-keys}}]))

# -- views ---------------------------------------------------------------
#
# Plain functions returning hiccup. `layout` is the resource's own so
# that this file renders the moment it is generated; point it at the
# application's layout and delete this one.

(defn layout [content context]
  (html/html5
    [:head
     [:meta {:charset "utf-8"}]
     [:title "{{plural-title}}"]
     [:script {:src "https://unpkg.com/htmx.org@2.0.7"}]]
    [:body [:main content]]))

(defn {{name}}-form
  ``The create/edit form — one function, because it is one schema. With
  a record it posts an update, without one it posts a create, and on an
  invalid submission the caller hands back the raw values and the
  schema errors and the same markup re-renders annotated.``
  [&opt record values errors]
  (def id (get record :id))
  (form/form {{entity}}Form
    {:action (if id (string "/{{plural}}/" id) "/{{plural}}")
     :values (or values record)
     :errors errors{{form-fields}}
     :submit (if id "Save" "Create")
     # the create route is a :void.htmx/partial, so the create form
     # swaps the fragment in place; the edit form is a plain POST
     :attrs (if id {} (hx/post "/{{plural}}" :target "#{{plural}}"
                               :swap :outer-html))}))

(defn {{plural}}-view
  "The list plus the create form — the fragment htmx swaps."
  [records &opt values errors]
  [:div {:id "{{plural}}"}
   [:h1 "{{plural-title}}"]
   ({{name}}-form nil values errors)
   [:ul {:class "{{plural}}"}
    (if (empty? records)
      [:li {:class "empty"} "Nothing here yet."]
      (seq [r :in records]
        [:li [:a {:href (string "/{{plural}}/" (r :id))}
              (string (get r {{display}} ""))]]))]])

(defn {{name}}-view
  "One record."
  [record]
  [:article
   [:h1 (string (get record {{display}} ""))]
   [:dl
    {{detail-rows}}]
   [:a {:href (string "/{{plural}}/" (record :id) "/edit")} "Edit"]])

# -- handlers ------------------------------------------------------------

(defn- recent
  "The list one page shows."
  []
  (db/query {{entity}} {:order-by [[:id :desc]] :limit 100}))

(defn- load-record
  "The record the path names, or a 404 — never a nil that reaches a
  template."
  [req]
  (def id (scan-number (get-in req [:params :id] "")))
  (unless id (errors/abort 404))
  (or (db/find {{entity}} id) (errors/abort 404)))

(defn index
  "GET /{{plural}} — the list and the create form."
  [req]
  (html/page ({{plural}}-view (recent)) {:layout layout}))

(defn new-record
  "GET /{{plural}}/new — an empty form."
  [req]
  (html/page ({{name}}-form) {:layout layout}))

(defn create
  "POST /{{plural}} — validate against the projection, then write."
  [req]
  (def result (form/check {{entity}}Form (req :form)))
  (if (empty? (result :errors))
    (do
      (db/insert! {{entity}} (result :value))
      (html/page ({{plural}}-view (recent)) {:layout layout}))
    (html/page ({{plural}}-view (recent) (req :form) (result :errors))
               {:layout layout})))

(defn show
  "GET /{{plural}}/:id"
  [req]
  (html/page ({{name}}-view (load-record req)) {:layout layout}))

(defn edit
  "GET /{{plural}}/:id/edit"
  [req]
  (html/page ({{name}}-form (load-record req)) {:layout layout}))

(defn update-record
  "POST /{{plural}}/:id — the same validation as create."
  [req]
  (def record (load-record req))
  (def result (form/check {{entity}}Form (req :form)))
  (if (empty? (result :errors))
    (do
      (db/update! {{entity}} (record :id) (result :value))
      (ring/redirect (string "/{{plural}}/" (record :id))))
    (html/page ({{name}}-form record (req :form) (result :errors))
               {:layout layout})))

(defn destroy
  "POST /{{plural}}/:id/delete"
  [req]
  (db/delete! {{entity}} ((load-record req) :id))
  (ring/redirect "/{{plural}}"))

# -- routes --------------------------------------------------------------
#
# A literal segment has to be declared before `:id` swallows it, so
# /new keeps its place above /:id. The route names are written out
# because they are also the policy names void/authz and void/admin ask
# about (ADR-0029) — one name, read by three things.

(router/defroutes :{{project}}/{{plural}}-routes
  (GET "/{{plural}}" index {:name :{{plural}}/index})
  (GET "/{{plural}}/new" new-record {:name :{{plural}}/new})
  (POST "/{{plural}}" create {:name :{{plural}}/create
                             :void.htmx/partial true})
  (GET "/{{plural}}/:id" show {:name :{{plural}}/show})
  (GET "/{{plural}}/:id/edit" edit {:name :{{plural}}/edit})
  (POST "/{{plural}}/:id" update-record {:name :{{plural}}/update})
  (POST "/{{plural}}/:id/delete" destroy {:name :{{plural}}/destroy}))

(plugin/defplugin {{plugin}}
  :doc "{{title}} resource: entity, form, CRUD routes."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1"
             :void/htmx ">=0.0.1" :void/db ">=0.0.1"})
```)

(def migration-template
  "The migration that creates the table the entity names."
  ```
### {{table}} — generated by `void make resource {{name}}`.
###
### What a step returns is executed: void/db/builder compiles the
### statement map for whichever engine is running, which is what keeps
### one migration file portable. Apply it with `void db migrate`.
(defn up []
  {:create-table "{{table}}"
   :columns [[:id :serial {:primary-key true}]
             {{columns}}]})

(defn down []
  {:drop-table "{{table}}"})
```)

(def test-template
  "The suite: the declarations still agree."
  ```
### The {{entity}} resource — generated by `void make resource`.
###
### Not one of these checks needs a database, and that is the point.
### They are about the *declarations* agreeing, which is the mistake
### this file's neighbours actually make: the entity, the form schema
### and the routes are three projections of one declaration, so a field
### renamed in one and not in the others fails here. The migration is
### the one thing that is not a projection — it is a separate file that
### created the columns — so it is read back as data and compared
### column by column.
###
### The CRUD path itself wants a driver in :plugins and `void db
### migrate` applied; void/test's inject (ADR-0017) then drives the
### routes without opening a socket.
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/db :as db)
(import ../{{dir}}/{{plural}} :as resource)

# -- the form schema is a projection of the entity ------------------------

(def valid
  "One record satisfying every field the entity declares."
  {{sample}})

(def checked (schema/check resource/{{entity}}Form valid))
(assert (empty? (checked :errors))
        (string "a valid {{name}} passes: " (string/format "%q" (checked :errors))))
{{empty-check}}
# -- the entity and the migration name the same columns -------------------

(def desc (db/resolve-entity resource/{{entity}}))
(def migration (dofile "{{migration-path}}"))
(def created
  (map |(db/snake (first $))
       (get ((get-in migration ['up :value])) :columns)))

(assert (= "{{table}}" (desc :table))
        "the entity and the migration agree on the table name")
(each c (desc :columns)
  (assert (index-of c created)
          (string "column " c " is declared by the entity but never created")))

# -- the routes are declared, under the names a policy asks about ---------

(def declared
  (get-in plugin/manifest-registry
          [:{{plugin}} :contributes :void.http/route-source 0 :routes :children]))
(def names (map |(get-in $ [:meta :name]) declared))

(each name [{{route-names}}]
  (assert (index-of name names) (string "route " name " is declared")))

(print "{{plural}}-test ok")
```)

(def empty-check-template
  "The half of the suite that only exists when a field is required."
  ```

(def empty-check (schema/check resource/{{entity}}Form {}))
(assert (not (empty? (empty-check :errors)))
        "an empty submission is refused by the schema, not by a handler")

```)

(defn- migration-path [spec]
  (string (spec :migrations-dir) "/" (spec :version)
          "_create_" (spec :table) ".janet"))

(defn- substitutions
  "Every hole the built-in templates have, filled from the spec. An
  override that wants one of them gets it by calling this."
  [spec]
  (def disp (display-field spec))
  (def ff (form-fields spec))
  (def rs (rels spec))
  {:name (spec :name)
   :entity (spec :entity)
   :plural (spec :plural)
   :table (spec :table)
   :title (spec :title)
   :plural-title (title (spec :plural))
   :plugin (spec :plugin)
   :project (spec :project)
   :dir (spec :dir)
   :version (spec :version)
   :migration-path (migration-path spec)
   :field-keys (field-keys spec)
   :display (string/format "%q" (disp :name))
   :sample (string "{" (sample-source spec) "}")
   :schema-fields
   (indent 3 (map |(string/format "%q %s" ($ :name) (node-source $)) (spec :fields)))
   :columns (indent 13 (map column-source (spec :fields)))
   :rels
   (if (empty? rs)
     ""
     (string "\n  :db/rels {"
             (indent 12 (map |(string/format "%q [:belongs-to %q %q]"
                                             ($ :rel) ($ :entity) ($ :name))
                             rs))
             "}"))
   :form-fields
   (if (empty? ff) "" (string "\n     :fields {" (indent 14 ff) "}"))
   :detail-rows
   (indent 4 (map |(string/format "[:dt %q] [:dd (string (get record %q \"\"))]"
                                  (title (string ($ :name))) ($ :name))
                  (spec :fields)))
   :route-names
   (string/join (map |(string/format ":%s/%s" (spec :plural) $)
                     ["index" "new" "create" "show" "edit" "update" "destroy"])
                "\n            ")})

(defn- render-resource [spec]
  (template/render resource-template (substitutions spec)))

(defn- render-migration [spec]
  (template/render migration-template (substitutions spec)))

(defn- render-test [spec]
  (def subs (substitutions spec))
  (template/render
    test-template
    (merge subs
           {:empty-check
            (if (every? (map |($ :optional?) (spec :fields)))
              ""
              (template/fill empty-check-template subs))})))

(def template
  ``The built-in resource template, as data: one entry per file, each
  with the `:key` a project override is named after, a `:path` and a
  pure `:render`. Nothing here touches the filesystem — `create`
  does.``
  [{:key :resource
    :path (fn [s] (string (s :dir) "/" (s :plural) ".janet"))
    :render render-resource}
   {:key :migration
    :path migration-path
    :render render-migration}
   {:key :test
    :path (fn [s] (string (s :test-dir) "/" (s :plural) "-test.janet"))
    :render render-test}])

# -- project overrides ---------------------------------------------------

(def override-dir
  "Where a project keeps its own templates."
  "templates/resource")

(defn override
  ``The project's replacement for one template entry, or the entry
  unchanged. An override is a Janet module at
  `templates/resource/<key>.janet` defining `render` — `(fn [spec]
  string)` — and optionally `path`. It is required, not evaluated in a
  sandbox: it is the project's own code, run by the project's own
  developer, the way `project.janet` is.``
  [entry &opt dir]
  (default dir override-dir)
  (def path (string dir "/" (entry :key) ".janet"))
  (unless (os/stat path :mode) (break entry))
  (def env (dofile path))
  (def render (get-in env ['render :value]))
  (unless (function? render)
    (errorf "template override %s must define (defn render [spec] ...)" path))
  (def custom-path (get-in env ['path :value]))
  (merge entry
         {:render render
          :source path}
         (if (function? custom-path) {:path custom-path} {})))

(defn templates
  "The template to render: the built-in entries with the project's
  overrides applied."
  [&opt dir]
  (map |(override $ dir) template))

# -- interactive ---------------------------------------------------------

(defn- ask-fields
  ``The interactive pass: fields, one at a time, until an empty name.
  It only runs when no field was given on the command line and there is
  a terminal to run it on — `void make resource User name:string` is
  the same command without the conversation.``
  []
  (def out @[])
  (print)
  (print "  Fields, one per line. An empty name finishes.")
  (print)
  (forever
    (def name (prompt/ask "  field name" {:default ""}))
    (when (empty? name) (break))
    (def type (prompt/choose "  type" field-types {:default :string}))
    (def entity
      (when (= :ref type)
        (prompt/ask "  belongs to which entity" {:default "User"})))
    (def optional? (prompt/confirm "  may it be empty?" false))
    (array/push out
                (parse-field
                  (string name ":" (string type)
                          (if entity (string ":" entity) "")
                          (if optional? "?" "")))))
  out)

# -- the project -----------------------------------------------------------

(defn project-name
  ``The application's name — the first half of the plugin keyword this
  resource contributes under. Read from `project.janet`, because that
  is where `void new` wrote it and where a renamed project changes it;
  the directory name is the fallback for a tree that has none.``
  [&opt root]
  (default root (os/cwd))
  (def dir-name (kebab (last (string/split "/" (string/trimr root "/")))))
  (def path (string root "/project.janet"))
  (or (when (os/stat path :mode)
        (def p (parser/new))
        (parser/consume p (slurp path))
        (parser/eof p)
        (var found nil)
        (while (parser/has-more p)
          (def form (parser/produce p))
          (when (and (indexed? form)
                     (= 'declare-project (first form)))
            (def kvs (drop 1 form))
            (loop [i :range [0 (length kvs)] :when (= :name (get kvs i))]
              (set found (get kvs (inc i))))))
        (when (string? found) (kebab found)))
      dir-name))

# -- create --------------------------------------------------------------

(def- flags-with-values
  {"--table" :table "--plural" :plural "--dir" :dir
   "--migrations-dir" :migrations-dir "--test-dir" :test-dir
   "--project" :project "--version" :version})

(defn- parse-args [args]
  (def opts @{})
  (def fields @[])
  (var name nil)
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (cond
      (in flags-with-values a)
      (do (when (>= (inc i) (length args)) (errorf "%s expects a value" a))
          (put opts (in flags-with-values a) (args (inc i)))
          (+= i 2))
      (= "--force" a) (do (put opts :force true) (++ i))
      (= "--dry-run" a) (do (put opts :dry-run true) (++ i))
      (= "--no-input" a) (do (put opts :no-input true) (++ i))
      (string/has-prefix? "--" a) (errorf "void make resource: unknown flag %q" a)
      (nil? name) (do (set name a) (++ i))
      (do (array/push fields (parse-field a)) (++ i))))
  [name fields opts])

(defn- ensure-dirs [path]
  (var cur "")
  (each part (drop -1 (string/split "/" path))
    (set cur (if (empty? cur) part (string cur "/" part)))
    (unless (os/stat cur) (os/mkdir cur))))

(defn resource
  ``The body of `void make resource NAME [field:type ...]`.

  Flags: `--table` / `--plural` (the pluralizer is a guess),
  `--dir` / `--migrations-dir` / `--test-dir` (where the files land),
  `--project` (the plugin's namespace), `--version` (the migration's,
  for a reproducible run), `--force` (overwrite), `--dry-run` (print
  instead of write) and `--no-input` (never ask, even on a terminal).

  Returns the tuple of paths written — or, under `--dry-run`, the
  paths it would have written.``
  [& args]
  (def [name fields opts] (parse-args args))
  (unless name (error "usage: void make resource NAME [field:type ...]"))
  # the conversation happens only when there is nothing to have it
  # about and somebody to have it with
  (def interactive?
    (and (empty? fields) (not (opts :no-input)) (prompt/interactive?)))
  (def all-fields
    (if interactive? (ask-fields) fields))
  (when (empty? all-fields)
    (error "a resource with no fields is a table with no columns — pass name:type arguments"))
  (def spec (resource-spec name all-fields
                           (merge {:project (project-name)} (table/to-struct opts))))
  (def entries (templates))
  (def planned
    (seq [e :in entries]
      {:path ((e :path) spec) :body ((e :render) spec) :source (get e :source)}))

  (when (opts :dry-run)
    (each p planned
      (print "# " (p :path) (if (p :source) (string "  (via " (p :source) ")") ""))
      (print (p :body)))
    (break (tuple ;(map |($ :path) planned))))

  (unless (opts :force)
    (def clashes (filter |(os/stat ($ :path) :mode) planned))
    (unless (empty? clashes)
      (errorf "refusing to overwrite %s (pass --force)"
              (string/join (map |($ :path) clashes) ", "))))

  (each p planned
    (ensure-dirs (p :path))
    (spit (p :path) (p :body))
    (print "  created " (p :path) (if (p :source) (string "  (via " (p :source) ")") "")))

  # what is *not* done, said in full: `make` does not edit main.janet
  # (see the module header), so the composition it needs is printed
  # rather than assumed. A resource is the first thing in a fresh
  # project that needs the entity layer and a driver at all.
  (print)
  (print "  add to :plugins in main.janet:")
  (print)
  (printf "    :%s%s the routes, the entity and the views"
          (spec :plugin) (string/repeat " " (max 1 (- 24 (length (spec :plugin))))))
  (print "    :void/db :void/db-sqlite  the entity layer and a driver, if not there yet")
  (print)
  (print "  then:")
  (print)
  (print "    void db migrate")
  (printf "    void dev                 # /%s" (spec :plural))
  (print)
  (tuple ;(map |($ :path) planned)))

# -- dispatch ------------------------------------------------------------

(def kinds
  "What `void make` can make. One entry today; the table is the reason
  a second one is a line rather than a rewrite of the dispatcher."
  {"resource" resource})

(defn create
  "The body of `void make KIND ...`."
  [& args]
  (def kind (first args))
  (unless kind
    (errorf "usage: void make KIND ... (one of: %s)"
            (string/join (sorted (keys kinds)) ", ")))
  (def f (or (in kinds kind)
             (errorf "void make: unknown kind %q (one of: %s)"
                     kind (string/join (sorted (keys kinds)) ", "))))
  (f ;(drop 1 args)))
