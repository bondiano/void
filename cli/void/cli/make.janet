### void/cli/make — `void make resource NAME field:type ...` and
### `void make auth [NAME]` (SPEC.md §5.17).
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
### `void make auth` is the same idea one layer up. The machinery has
### been there since wave 3 — `auth/password`, the identity, the
### strategies, `challenge!` and the sessions — and every application
### still wrote the same five pages by hand. The generator writes them
### from one declaration too: the entity is the users table
### `void/auth-db` reads, the registration form is `schema/select` over
### it, the migration creates exactly those columns next to the two
### tables `void/auth-db` owns, and reset and verification are the same
### `challenge!` with one claim to tell them apart.
###
### **Templates are data.** Each generator's built-in set is a tuple of
### `{:key :path :render}` entries whose `:render` is a pure
### `(fn [spec] string)`, exactly as in ./new. A project overrides one
### by dropping a Janet module at `templates/<kind>/<key>.janet` that
### defines `render` (and, if the file should land elsewhere, `path`).
### There is deliberately no second templating language: a project that
### wants its own layout writes Janet, which is what it is going to
### edit the output in anyway.
###
### **Nothing existing is edited.** `make` writes new files, refuses to
### clobber (`--force` to insist) and *prints* what has to be added to
### `project.janet`, `main.janet` and a config file rather than reaching
### into them. A generator that rewrites hand-edited code is a generator
### nobody dares run twice — phx.gen.auth edits the router because it
### can pattern-match one line of Elixir it wrote itself, and the three
### files here are not that.
###
### The whole price of that decision is `auth-report`: everything the
### scaffold *made necessary* elsewhere has to be printed, in full, in
### one place. A generator that stays out of your files and then does
### not say what it needs has not been careful, it has been quiet — and
### the failures are exactly the kind nobody attributes to a generator
### (a suite that will not import, a page whose script the browser
### refuses with nothing in the terminal to say so).
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

# -- flag values ---------------------------------------------------------
#
# Every flag value ends up in a path, a table name or generated source,
# so each is checked once, here, rather than discovered as a file four
# directories above the project (`--dir ../../..`) or a migration that
# does not parse.

(defn- check-word
  "A flag value that becomes an identifier — a table, a plural, a
  project name."
  [flag value]
  (unless (peg/match '(* (range "az") (any (+ (range "az") (range "09") "-" "_")) -1)
                     (string value))
    (errorf "%s %q must be a word: a lowercase letter, then letters, digits, - or _"
            flag value))
  value)

(defn- check-subpath
  "A flag value that becomes a directory — inside the project, always."
  [flag value]
  (def s (string value))
  (when (or (empty? s)
            (string/has-prefix? "/" s)
            (some |(or (empty? $) (= ".." $)) (string/split "/" s)))
    (errorf "%s %q must be a relative path inside the project (no leading /, no .. and no empty segments)"
            flag s))
  s)

(defn- check-version [value]
  (unless (peg/match '(* (some (range "09")) -1) (string value))
    (errorf "--version %q must be digits — a migration timestamp like 20260101120000"
            value))
  value)

(defn- check-spec-opts
  "The flag values common to both generators, checked by what each
  becomes. `:dir` is separate because auth allows an empty one (the
  module lands beside app.janet)."
  [opts]
  (when-let [v (get opts :plural)] (check-word "--plural" v))
  (when-let [v (get opts :table)] (check-word "--table" v))
  (when-let [v (get opts :project)] (check-word "--project" v))
  (when-let [v (get opts :version)] (check-version v))
  (when-let [v (get opts :migrations-dir)] (check-subpath "--migrations-dir" v))
  (when-let [v (get opts :test-dir)] (check-subpath "--test-dir" v))
  opts)

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
  (check-spec-opts opts)
  (when-let [d (get opts :dir)] (check-subpath "--dir" d))
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
     [:script {:src "https://unpkg.com/htmx.org@4.0.0"}]]
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
  "Where a project keeps its own resource templates."
  "templates/resource")

(def auth-override-dir
  "Where a project keeps its own auth templates."
  "templates/auth")

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

(defn- own-migration-version
  ``The version of an earlier run's `_create_<table>` migration in
  `dir`, newest if there are several. A `--force` re-run adopts it so
  the rewrite lands on the same file — a second CREATE TABLE with a
  fresh timestamp is an orphan the next `void db migrate` trips over.``
  [dir table]
  (def suffix (string "_create_" table ".janet"))
  (when (= :directory (os/stat dir :mode))
    (last (sorted (seq [f :in (os/dir dir)
                        :when (string/has-suffix? suffix f)
                        :let [v (string/slice f 0 (- (length f) (length suffix)))]
                        :when (peg/match '(* (some (range "09")) -1) v)]
                    v)))))

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
  (def spec-opts (merge {:project (project-name)} (table/to-struct opts)))
  (def spec
    (let [s (resource-spec name all-fields spec-opts)]
      # --force without an explicit --version replaces its own earlier
      # migration instead of leaving it orphaned beside a new one
      (if-let [v (and (opts :force) (nil? (opts :version))
                      (own-migration-version (s :migrations-dir) (s :table)))]
        (resource-spec name all-fields (merge spec-opts {:version v}))
        s)))
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

# -- auth ----------------------------------------------------------------
#
# Everything below generates the five pages every application writes
# by hand on top of machinery it already has: register, sign in, sign
# out, reset a password and verify an address. The two challenges are
# one flow — `auth/challenge!` mints a single-use code, a
# `:void.auth/deliver` gets it to the person, and one route redeems it
# — so what separates them is a claim on the challenge and nothing
# else. Which is why there is one redeem route: a deliverer builds its
# URL from `[:mail-auth :link-path]`, and that is a single path.

(def auth-reserved
  ``Columns the scaffold declares itself. An extra field that names
  one of them would generate a duplicate key in the entity and a
  duplicate column in the migration, so it is refused by name here
  rather than by the parser three files later.``
  [:id :email :password :password-hash :verified-at :created-at])

(defn auth-spec
  ``The value every auth template is a pure function of:

      {:name "user" :entity "User" :plural "users" :table "users"
       :title "User" :project "demo" :plugin "demo/auth"
       :dir "" :module-path "auth" :link-path "/auth/link"
       :driver :void/db-sqlite :version "..." :fields [...]}

  `:fields` are the *extra* profile columns — the four the scaffold
  always declares are not in it, because they are not the caller's to
  rename.``
  [&opt name fields opts]
  (default name "user")
  (default fields [])
  (default opts {})
  (def base (kebab name))
  (unless (peg/match '(* (range "az") (any (+ (range "az") (range "09") "-")) -1) base)
    (errorf "account name %q must be a word (User, account, team-member) — it becomes the table and the subject kind (\"%s:42\")"
            name base))
  (each f fields
    (when (index-of (f :name) auth-reserved)
      (errorf "field %q is one the auth scaffold already declares (%s)"
              (f :name)
              (string/join (map |(string/format "%q" $) auth-reserved) " "))))
  (check-spec-opts opts)
  # auth's --dir may be empty (the module lands beside app.janet)
  (when-let [d (get opts :dir)]
    (unless (empty? (string d)) (check-subpath "--dir" d)))
  (when-let [lp (get opts :link-path)]
    (unless (string/has-prefix? "/" (string lp))
      (errorf "--link-path %q must be an absolute path of this application, like /auth/link" lp)))
  (def plural-name (or (get opts :plural) (plural base)))
  (def project (get opts :project "app"))
  (def dir (get opts :dir ""))
  {:name base
   :entity (pascal base)
   :plural plural-name
   :table (or (get opts :table) (snake plural-name))
   :title (title base)
   :project project
   :plugin (string project "/auth")
   :dir dir
   :module-path (if (empty? dir) "auth" (string dir "/auth"))
   :link-path (get opts :link-path "/auth/link")
   :driver (get opts :driver :void/db-sqlite)
   :migrations-dir (get opts :migrations-dir "db/migrations")
   :test-dir (get opts :test-dir "test")
   :version (or (get opts :version) (timestamp))
   :fields (tuple ;fields)})

(defn- block
  "Extra lines, indented under a line the template already opened —
  empty when there are no extra fields, which is the common case."
  [n lines]
  (if (empty? lines)
    ""
    (let [pad (string "\n" (string/repeat " " n))]
      (string pad (string/join lines pad)))))

(def auth-template
  "The accounts module: entity, form projections, views, handlers, routes."
  ```
### {{plugin}} — accounts: register, sign in, sign out, reset, verify.
###
### Generated by `void make auth`. Every page here stands on machinery
### that was already in the composition; what the generator wrote is
### the part that is the same in every application and different in
### none of the interesting ways.
###
### The accounts table below is **the application's**: void/auth-db
### reads it (`[:auth-db :users]` says which columns) and never writes
### to it, so registration and a password change are handlers here
### rather than something a plugin does behind them. The sign-up form
### is `schema/select` over that same entity plus the one field that is
### not a column, so a field added to the entity shows up in the form
### with its validation already attached (ADR-0008).
###
### **Reset and verification are one flow.** `auth/challenge!` mints a
### single-use code and hands it to whatever delivers (`:void/mail-auth`
### is one; a challenge nobody delivered is an error, ADR-0023 §7).
### There is **one** route that redeems, because a deliverer builds one
### URL — from `[:mail-auth :link-path]` — and which of the two the
### link was for is a claim that travelled on the challenge.
###
### **CSRF is one word here, on three routes.** `form/form` has been
### splicing the token slot since wave 1 and void/security binds it
### (ADR-0025) — the forms below carry a token because they are forms.
### The check, though, fires on cookie-borne requests — and the POSTs a
### visitor makes *before* they have a session (login, register, the
### reset request) carry no cookie, which is exactly the login-CSRF
### hole. Those three routes ask for the check by name, with the
### `:void.security/csrf` route flag.
###
### Handlers are registered as symbols, so redefining one in the repl —
### or saving this file with `void dev` running — is live (ADR-0002).
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/db :as db)
(import void/auth :as auth)
(import void/auth/http :as auth-http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/wire :as wire)
(import void/html :as html)
(import void/html/form :as form)

# -- the declaration -----------------------------------------------------

(db/defentity {{entity}}
  {:id [:int {:db/pk true :db/type "integer"}]
   :email [:string {:format :email :db/unique true :db/type "text"}]
   # a PHC string ($scrypt$ln=14,r=8,p=1$…), written by
   # `auth/hash-password` and read by void/auth-db's user store. It is
   # optional because an account that only ever arrives by link never
   # sets one — and void/auth's password strategy answers
   # :no-password for it after spending the time it would have spent
   # on a real check
   :password-hash [:optional [:string {:db/type "text"}]]
   :verified-at [:optional [:string {:db/type "text"}]]
   :created-at [:optional [:string {:db/type "text"}]]{{schema-fields}}}
  :db/table "{{table}}")

# -- what the forms submit: projections of the entity, not copies --------

(def Registration
  ``The sign-up form. `schema/merge` composes the projection of the
  entity with the one field that has no place in it — the hash is what
  the table stores, and the plaintext exists for exactly the length of
  one request (ADR-0023 §4).``
  (schema/merge (schema/select {{entity}} [:email{{field-keys}}])
                {:password [:string {:min 8 :max 200}]}))

(def Credentials
  "What the sign-in form submits."
  {:email [:string {:format :email}]
   :password [:string {:min 1 :max 200}]})

(def EmailOnly
  "What the \"mail me a reset link\" form submits — an address, and
  deliberately nothing else."
  {:email [:string {:format :email}]})

(def NewPassword
  "What the change-password form submits."
  {:password [:string {:min 8 :max 200}]})

# -- the account behind the identity -------------------------------------
#
# An identity is `{:subject "{{name}}:42" ...}` and nothing more
# (ADR-0023): void does not know what a user is, and these three
# functions are where this application says what one is.

(defn- now
  "An ISO-8601 UTC timestamp — text on every engine, which is what
  keeps the migration one file."
  []
  (def d (os/date (os/time) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn subject-string
  "The subject a record signs in as — `[:auth-db :users :subject-kind]`
  is the `{{name}}` half of it."
  [record]
  (string "{{name}}:" (record :id)))

(defn- find-by-email [email]
  (when email (db/one {{entity}} {:where [:= :email email]})))

(defn- record-of
  "The row an identity points at, or nil."
  [id]
  (when id
    (when-let [n (scan-number (last (auth/subject-of (id :subject))))]
      (db/find {{entity}} n))))

(defn current-record
  "The signed-in account as a row, or nil."
  []
  (record-of (auth/current-user)))

(defn send-verification!
  ``Ask somebody to confirm the address they registered with. The
  claim is what tells this challenge from a password reset when the
  link comes back — `challenge!` refuses if nobody delivered it, which
  is the failure you want: a page that spins forever with nothing in
  any log is the other one.``
  [record]
  (auth/challenge! (subject-string record)
                   {:to (record :email)
                    :claims {:purpose "verify"}}))

(defn- mark-verified! [id]
  (when-let [record (record-of id)]
    (unless (record :verified-at)
      (db/update! {{entity}} (record :id) {:verified-at (now)}))))

(defn- next-path
  ``Where a redirected visitor was going. void/auth-http sends an
  unauthenticated request to `[:auth-http :login-path]` with `?next=`,
  and this reads it back — as **a path of this application and nothing
  else**. A `next` that starts a scheme or `//` is somebody else's
  origin, and following it is an open redirect with a sign-in page
  attached.``
  [req]
  (def raw (get (or (req :query) {}) "next"))
  (if (and raw (string/has-prefix? "/" raw) (not (string/has-prefix? "//" raw)))
    raw
    "/"))

# -- views ---------------------------------------------------------------
#
# Plain functions returning hiccup. `layout` is this module's own so
# that these pages render the moment they are generated; point it at
# the application's layout and delete this one.

(defn who-bar
  "Who is signed in, and the way out."
  []
  (if (auth/current-user)
    [:p {:class "who"}
     # the claim comes off the identity, which void/auth-http re-read
     # from the store on this request — no second query for a greeting
     "Signed in as " [:strong (or (auth/claim :email) (auth/subject))] " · "
     [:a {:href "/verify"} "Your address"] " "
     (form/form {} {:action "/logout" :submit "Sign out"})]
    [:p {:class "who"}
     [:a {:href "/login"} "Sign in"] " · "
     [:a {:href "/register"} "Create an account"]]))

(defn layout [content context]
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "{{project}}"]]
    [:body
     [:header (who-bar)]
     [:main content]]))

(defn- page [content]
  (html/page content {:layout layout}))

(defn- message-line [state]
  (when-let [m (get state :message)] [:p {:class "message"} m]))

(defn register-view
  ``The sign-up page. `state` is whatever the handler wants
  re-rendered: :values and :errors put an invalid submission back in
  the form annotated, :message is the one line it is allowed to say.``
  [&opt state]
  (default state {})
  [:div {:id "register"}
   [:h1 "Create an account"]
   (message-line state)
   (form/form Registration
     {:action "/register"
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}{{form-fields}}}
      :submit "Create an account"})
   [:p [:a {:href "/login"} "Already have an account?"]]])

(defn login-view
  "The sign-in page. :next is where the visitor was going before
  void/auth-http sent them here."
  [&opt state]
  (default state {})
  (def target (get state :next))
  [:div {:id "login"}
   [:h1 "Sign in"]
   (message-line state)
   (form/form Credentials
     {:action (if target (string "/login?next=" (wire/url-encode target)) "/login")
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Sign in"})
   [:p [:a {:href "/password/reset"} "Forgot your password?"] " · "
    [:a {:href "/register"} "Create an account"]]])

(defn reset-view
  "Ask for the address a reset link goes to."
  [&opt state]
  (default state {})
  [:div {:id "reset"}
   [:h1 "Reset your password"]
   (message-line state)
   (form/form EmailOnly
     {:action "/password/reset"
      :values (get state :values)
      :errors (get state :errors)
      :submit "Mail me a link"})])

(defn password-view
  "Set a new password — reached by following a reset link, or from an
  account page."
  [&opt state]
  (default state {})
  [:div {:id "password"}
   [:h1 "Choose a new password"]
   (message-line state)
   (form/form NewPassword
     {:action "/password"
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Save"})])

(defn verify-view
  "Where the confirmation link is asked for again — a link expires, and
  a flow with no way to send a second one is a dead end with a support
  ticket attached."
  [record]
  [:div {:id "verify"}
   [:h1 "Your address"]
   (if (get record :verified-at)
     [:p {:class "message"}
      (string (get record :email "") " is confirmed.")]
     [:div
      [:p "We sent a confirmation link to "
       [:strong (get record :email "")] "."]
      (form/form {} {:action "/verify" :submit "Send it again"})])])

(defn notice-view
  "One line, and nothing to fill in."
  [message]
  [:div {:id "notice"} [:p {:class "message"} message]])

# -- handlers ------------------------------------------------------------

(defn register-form
  "GET /register"
  [req]
  (page (register-view)))

(defn register
  ``POST /register — an account with a password.

  The sign-in that follows goes through the ordinary password path
  rather than trusting the row that was just written: one code path
  signs anybody in, so there is one place where that can be wrong.``
  [req]
  (def result (form/check Registration (req :form)))
  (def v (result :value))
  (def taken (and (empty? (result :errors)) (find-by-email (v :email))))
  (cond
    (not (empty? (result :errors)))
    (page (register-view {:values (req :form) :errors (result :errors)}))

    taken
    (page (register-view {:values (req :form)
                          :message "That address already has an account — sign in instead."}))

    (do
      (def created
        (db/insert! {{entity}}
                    {:email (v :email){{inserts}}
                     :password-hash (auth/hash-password (v :password))
                     :created-at (now)}))
      (def check (auth/check-password (auth/user-store)
                                      {:email (v :email) :password (v :password)}))
      (auth-http/login! req (check :identity))
      (send-verification! created)
      (ring/redirect "/"))))

(defn login-form
  "GET /login — where [:auth-http :login-path] points."
  [req]
  (page (login-view {:next (get (or (req :query) {}) "next")})))

(defn login
  ``POST /login — the password path, and nothing else.

  Whatever went wrong, the page says the same thing:
  `check-password` distinguishes an unknown address from a wrong
  password and spends the same time on both (it hashes even when
  there is no account), and telling the visitor which it was would
  hand that distinction straight back.``
  [req]
  (def result (form/check Credentials (req :form)))
  (def check (when (empty? (result :errors))
               (auth/check-password (auth/user-store) (result :value))))
  (if-let [id (get check :identity)]
    (do
      (auth-http/login! req id)
      (ring/redirect (next-path req)))
    (page (login-view {:values (req :form)
                       :next (get (or (req :query) {}) "next")
                       :message "Those credentials do not match an account."}))))

(defn logout
  "POST /logout — drop the identity and rotate the session id."
  [req]
  (auth-http/logout! req)
  (ring/redirect "/"))

(defn reset-form
  "GET /password/reset"
  [req]
  (page (reset-view)))

(defn request-reset
  ``POST /password/reset — mail a link that signs them in long enough
  to choose a new password.

  **The answer is the same whether or not the address has an
  account.** A page that said "no such account" would be a way to ask
  this application who its {{plural}} are, one address at a time — the
  same reasoning that makes `check-password` spend its time on an
  unknown login.``
  [req]
  (def result (form/check EmailOnly (req :form)))
  (def record (when (empty? (result :errors))
                (find-by-email (get-in result [:value :email]))))
  (when record
    (auth/challenge! (subject-string record)
                     {:to (record :email)
                      :claims {:purpose "reset"}}))
  (page (reset-view
          {:values (req :form)
           :message (if (empty? (result :errors))
                      "If that address has an account, a link is on its way."
                      "That does not look like an email address.")})))

(defn link
  ``GET {{link-path}}?h=&c= — the one path a letter points at
  ([:mail-auth :link-path]), for both challenges.

  `redeem!` takes the challenge out of the store *before* it checks
  the code (ADR-0023 §7), so a link works once and a wrong one is
  spent: the visitor asks for another, which costs them a click and an
  attacker a full guess per try. What the link was for is a claim that
  travelled on the challenge — no second table, and no second route.``
  [req]
  (def query (or (req :query) {}))
  (if-let [id (auth/redeem! (get query "h") (get query "c"))]
    (do
      (auth-http/login! req id)
      (if (= "reset" (get-in id [:claims :purpose]))
        (ring/redirect "/password/edit")
        (do
          (mark-verified! id)
          (ring/redirect "/"))))
    (page (login-view
            {:message "That link has expired or has already been used."}))))

(defn password-form
  "GET /password/edit"
  [req]
  (page (password-view)))

(defn update-password
  "POST /password — the route is :required, so there is somebody to
  change the password of."
  [req]
  (def result (form/check NewPassword (req :form)))
  (def record (current-record))
  (if (or (not (empty? (result :errors))) (nil? record))
    (page (password-view {:values (req :form) :errors (result :errors)}))
    (do
      (db/update! {{entity}} (record :id)
                  {:password-hash (auth/hash-password (get-in result [:value :password]))})
      (page (notice-view "Your password has been changed.")))))

(defn verify-form
  "GET /verify"
  [req]
  (page (verify-view (current-record))))

(defn resend-verification
  "POST /verify — another confirmation link for the signed-in account.
  A confirmed address does not get one: the link signs whoever holds
  it in, and there is no reason to keep minting those."
  [req]
  (when-let [record (current-record)]
    (unless (record :verified-at)
      (send-verification! record)))
  (page (notice-view "A confirmation link is on its way.")))

# -- routes --------------------------------------------------------------
#
# Every route says what access it needs rather than leaning on
# [:auth-http :default]: the default is :public, an application that
# flips it to :required has taken a deny-by-default posture on purpose,
# and these twelve routes have to keep meaning the same thing under
# both. The names are also what a policy asks about (ADR-0029) — one
# name, read by more than one thing.

(router/defroutes :{{project}}/auth-routes
  (GET "/register" register-form {:name :auth/register-form
                                  :void.auth/access :public})
  # the three anonymous POSTs carry no session cookie, so the
  # cookie-borne CSRF rule never sees them — login CSRF (being signed
  # into an attacker's account) needs the check asked for by name
  (POST "/register" register {:name :auth/register
                              :void.auth/access :public
                              :void.security/csrf true})
  (GET "/login" login-form {:name :auth/login-form
                            :void.auth/access :public})
  (POST "/login" login {:name :auth/login
                        :void.auth/access :public
                        :void.security/csrf true})
  (POST "/logout" logout {:name :auth/logout
                          :void.auth/access :public})
  (GET "/password/reset" reset-form {:name :auth/reset-form
                                     :void.auth/access :public})
  (POST "/password/reset" request-reset {:name :auth/reset-request
                                         :void.auth/access :public
                                         :void.security/csrf true})
  # a GET that signs somebody in is safe here for the reason a password
  # POST is: the credential is in the URL and it is single-use
  (GET "{{link-path}}" link {:name :auth/link :void.auth/access :public})
  (GET "/password/edit" password-form {:name :auth/password-form
                                       :void.auth/access :required})
  (POST "/password" update-password {:name :auth/password-update
                                     :void.auth/access :required})
  (GET "/verify" verify-form {:name :auth/verify-form
                              :void.auth/access :required})
  (POST "/verify" resend-verification {:name :auth/verify-resend
                                       :void.auth/access :required}))

(plugin/defplugin {{plugin}}
  :doc "{{title}} accounts: register, sign in, sign out, password reset and address verification, over void/auth."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/db ">=0.0.1"
             :void/auth ">=0.0.1" :void/auth-http ">=0.0.1"
             :void/auth-db ">=0.0.1"})
```)

(def auth-migration-template
  "The users table, and the two tables void/auth-db owns beside it."
  ```
### {{table}} — generated by `void make auth {{name}}`.
###
### Two owners, one file. `{{table}}` is the application's:
### void/auth-db *reads* it (`[:auth-db :users]` says which columns)
### and never writes to it, which is why registration and a password
### change are handlers in {{module-path}}.janet. The other two tables
### are void's own — API-token digests and single-use one-time codes —
### and void/auth-db ships their DDL as data rather than as a migration
### of its own, because a migration timeline belongs to the application
### (ADR-0023 §2).
###
### What a step returns is executed: void/db/builder compiles the
### statements for whichever engine is running, which is what keeps one
### migration file portable. Apply it with `void db migrate`.
(import void/auth/db :as auth-db)

(defn up []
  [{:create-table "{{table}}"
    :columns [[:id :serial {:primary-key true}]
              [:email :text {:null false :unique true}]
              # a PHC string: the algorithm and its cost travel inside
              # the value, so raising the cost later is a config change
              # rather than a migration nobody can write (ADR-0023 §4).
              # Nullable — an account that only arrives by link has none
              [:password-hash :text]
              # text on both engines, so a row reads the same on either
              [:verified-at :text]
              [:created-at :text]{{columns}}]}
   ;(auth-db/tables)])

(defn down []
  [;(auth-db/drop-tables)
   {:drop-table "{{table}}"}])
```)

(def auth-test-template
  "The suite: every flow the scaffold ships, through the real stack."
  ```
### The accounts scaffold — generated by `void make auth`.
###
### Every flow driven the way a browser drives it: test/inject
### (ADR-0017) runs a request through the whole chain — the session,
### the CSRF check, the strategy chain, the route table — without
### opening a socket, so what passes here is what a browser gets.
###
### **The composition is written out** rather than read from
### main.janet, so that this suite runs the moment it is generated —
### before those plugins have been added there. Once they have, replace
### the list with main.janet's and the suite follows the application.
###
### **Delivery is a plugin of this file's own.** `auth/challenge!`
### refuses a challenge nobody delivered (ADR-0023 §7); in production
### :void/mail-auth is what delivers, and here it is five lines that
### keep the code where an assertion can read it — which is how the
### reset and the verification are proven without a mailbox.
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
# importing a plugin's module is what registers its manifest, which is
# what makes a keyword entry in :plugins below resolvable. The module
# under test imports void/auth and void/auth-http itself; these four it
# does not name, and they are in the composition all the same
(import void/crypto)
(import void/auth/db)
(import void/security)
(import {{driver-module}})
(import ../{{module-path}} :as accounts)

# -- the deliverer -------------------------------------------------------

(def delivered
  "Every challenge this suite caused, newest last."
  @[])

(def capture
  (plugin/manifest 'test/capture-challenges
    :doc "Keeps magic links where an assertion can read them."
    :contributes {:void.auth/deliver
                  [{:name :test/capture
                    :fn (fn capture [payload]
                          (array/push delivered payload)
                          true)}]}))

# -- the composition -----------------------------------------------------

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp")
          "/{{project}}-auth-test-" (os/time) ".sqlite3"))

(def plugins
  [:void/http :void/html
   :void/db {{driver}}
   # every hash and every code comes from void/crypto (ADR-0022): this
   # composition hashes nothing itself
   :void/crypto :void/auth :void/auth-http :void/auth-db
   # the CSRF token the forms below carry without asking (ADR-0025)
   :void/security
   capture
   :{{plugin}}])

(def config
  {:env @{}
   :cli {:db {:migrations {:dir "{{migrations-dir}}"}}
         :db-sqlite {:path sqlite-path}
         :http {:session {:enabled true}}
         # three interfaces have two implementations each — the memory
         # stores void/auth ships and the database ones void/auth-db
         # does — and the kernel refuses to guess (ADR-0030)
         :void/auth-user-store {:impl :auth.db/users}
         :void/auth-token-store {:impl :auth.db/tokens}
         :void/auth-challenge-store {:impl :auth.db/challenges}
         :auth-db {:users {:table "{{table}}"
                           :subject-kind "{{name}}"
                           :email-column "email"
                           :password-column "password_hash"
                           # on the identity, so a page can greet
                           # somebody without a second query
                           :claims-columns ["email"]}}
         :auth-http {:unauthenticated :redirect :login-path "/login"}
         # what the configured hasher costs is pinned in void/crypto;
         # this suite signs in a dozen times and does not need it
         :auth {:scrypt {:ln 10}}
         :crypto {:kdf {:in-thread false}}}})

# -- helpers -------------------------------------------------------------

(defn- text [resp] (test/text resp))

(defn- token-of
  "The CSRF token out of a rendered form — no page below asked for one."
  [resp]
  (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`))) (text resp))))

(defn- message-of
  "The one line a page is allowed to say."
  [resp]
  (first (peg/match ~(* (thru `class="message">`) (<- (to "<"))) (text resp))))

(defn- token-for [client uri]
  (or (token-of (test/inject client {:uri uri}))
      (errorf "no CSRF token on %s" uri)))

(defn- link-of [challenge]
  (string "{{link-path}}?h=" (challenge :handle) "&c=" (challenge :code)))

(log/set-sinks! [(fn [_])])

(test/with-http [c {:plugins plugins
                    :profile :test
                    :config config
                    :only [:http/kernel :crypto/lib :auth/registry]}]
  (db/migrate-up! {:dir "{{migrations-dir}}"})

  # -- registration ------------------------------------------------------

  (def form-page (test/inject c {:uri "/register"}))
  (assert (= 200 (form-page :status)) "the sign-up page renders")
  (assert (token-of form-page)
          "and carries a CSRF token nobody wrote a line for: form/form splices the slot, void/security binds it")

  (def registered
    (test/inject c {:uri "/register"
                    :headers {"x-csrf-token" (token-of form-page)}
                    :form {:email "ada@example.com"
                           :password "correct horse battery"{{sample}}}}))
  (assert (= 302 (registered :status)) "registering signs the visitor in")

  (def ada (db/one accounts/{{entity}} {:where [:= :email "ada@example.com"]}))
  (assert ada "the account is a row in {{table}}")
  (assert (not (string/find "correct horse" (ada :password-hash)))
          "and the column holds a hash, not the password")
  (assert (string/has-prefix? "$" (ada :password-hash))
          "a PHC string: the algorithm and its cost travel inside the value")

  # an anonymous POST carries no session cookie, which is exactly the
  # request the cookie-borne rule cannot see — the route asks for the
  # check by name (:void.security/csrf true), so login CSRF is closed
  (assert (= 403 ((test/inject (test/client (c :boot))
                               {:uri "/register"
                                :form {:email "eve@example.com"
                                       :password "any password"{{sample}}}})
                  :status))
          "an anonymous POST without the token is refused — signing a visitor into an account they did not ask for is CSRF too")

  (def second-visitor (test/client (c :boot)))
  (def taken
    (test/inject second-visitor
                 {:uri "/register"
                  :headers {"x-csrf-token" (token-for second-visitor "/register")}
                  :form {:email "ada@example.com"
                         :password "another password"{{sample}}}}))
  (assert (string/find "already has an account" (text taken))
          "a second account for the same address is refused, and says so")
  (assert (= 1 (db/count accounts/{{entity}})))

  # -- verifying the address ---------------------------------------------

  (assert (= 1 (length delivered))
          "registering asks the visitor to confirm their address — and challenge! would have raised if nobody delivered it")
  (assert (= "verify" (get-in (last delivered) [:claims :purpose]))
          "the claim is what tells this challenge from a reset")
  (assert (= "ada@example.com" ((last delivered) :to)))
  (assert (not (ada :verified-at)) "not verified until the link is followed")

  # a link expires in fifteen minutes; a flow with no second one is a
  # dead end with a support ticket attached
  (assert (string/find "We sent a confirmation link"
                       (text (test/inject c {:uri "/verify"}))))
  (assert (= 200 ((test/inject c {:method :post :uri "/verify"
                                  :headers {"x-csrf-token" (token-for c "/password/edit")}})
                  :status)))
  (assert (= 2 (length delivered)) "and asking again sends another")

  (def verification (last delivered))
  (assert (= 302 ((test/inject c {:uri (link-of verification)}) :status)))
  (assert ((db/find accounts/{{entity}} (ada :id)) :verified-at)
          "following the link is what marks the address verified")

  (def replayed (test/inject (test/client (c :boot))
                             {:uri (link-of verification)}))
  (assert (string/find "expired or has already been used" (text replayed))
          "a link works once: redeem takes the challenge out of the store before it checks the code")

  (assert (string/find "is confirmed" (text (test/inject c {:uri "/verify"}))))
  (array/clear delivered)
  (assert (= 200 ((test/inject c {:method :post :uri "/verify"
                                  :headers {"x-csrf-token" (token-for c "/password/edit")}})
                  :status)))
  (assert (empty? delivered)
          "and a confirmed address stops minting links that sign whoever holds them in")

  # -- signing out, and back in ------------------------------------------

  (assert (= 302 ((test/inject c {:method :post :uri "/logout"
                                  :headers {"x-csrf-token" (token-for c "/login")}})
                  :status)))

  (def anon-token (token-for c "/login"))
  (defn- sign-in [email password]
    (test/inject c {:uri "/login"
                    :headers {"x-csrf-token" anon-token}
                    :form {:email email :password password}}))

  (def wrong (sign-in "ada@example.com" "not it"))
  (def unknown (sign-in "nobody@example.com" "not it"))
  (assert (= (wrong :status) (unknown :status)))
  (assert (= (message-of wrong) (message-of unknown))
          "a wrong password and an unknown address say exactly the same thing — telling them apart is a user-enumeration API, and check-password spends the same time on both")
  (each said ["no such" "unknown" "wrong password" "not registered"]
    (assert (not (string/find said (string/ascii-lower (text unknown))))
            (string "and the page does not say " said)))

  (assert (= 302 ((sign-in "ada@example.com" "correct horse battery") :status))
          "the right password signs in")

  # -- CSRF ---------------------------------------------------------------
  #
  # The credential rides on a cookie, which is exactly when CSRF
  # applies (ADR-0025 §1).

  (assert (= 403 ((test/inject c {:uri "/password"
                                  :form {:password "a password from nowhere"}})
                  :status))
          "a signed-in POST without the token is refused before the handler runs")

  # -- what :void.auth/access :required means ------------------------------

  (def anon (test/client (c :boot)))
  (def redirected (test/inject anon {:uri "/password/edit"}))
  (assert (= 302 (redirected :status))
          "an unauthenticated request to a protected route goes to the sign-in page, because this composition said :redirect")
  (assert (string/has-prefix? "/login?next=" (get-in redirected [:headers "location"]))
          "carrying where it was going")

  # -- the reset ----------------------------------------------------------

  (array/clear delivered)
  (def visitor (test/client (c :boot)))
  (def asked
    (test/inject visitor {:uri "/password/reset"
                          :headers {"x-csrf-token" (token-for visitor "/password/reset")}
                          :form {:email "ada@example.com"}}))
  (assert (string/find "on its way" (text asked)))
  (assert (= 1 (length delivered)))
  (def reset (last delivered))
  (assert (= "reset" (get-in reset [:claims :purpose])))

  (def landed (test/inject visitor {:uri (link-of reset)}))
  (assert (= "/password/edit" (get-in landed [:headers "location"]))
          "the link signs them in and lands on the form for a new password")

  (def edit (test/inject visitor {:uri "/password/edit"}))
  (assert (= 200 (edit :status)))
  (assert (= 200 ((test/inject visitor {:uri "/password"
                                        :headers {"x-csrf-token" (token-of edit)}
                                        :form {:password "a longer new password"}})
                  :status)))

  (def after (test/client (c :boot)))
  (defn- try-login [password]
    (test/inject after {:uri "/login"
                        :headers {"x-csrf-token" (token-for after "/login")}
                        :form {:email "ada@example.com" :password password}}))
  (assert (= 200 ((try-login "correct horse battery") :status))
          "the old password no longer signs anybody in")
  (assert (= 302 ((try-login "a longer new password") :status))
          "and the new one does")

  (array/clear delivered)
  (def stranger
    (test/inject visitor {:uri "/password/reset"
                          :headers {"x-csrf-token" (token-for visitor "/password/reset")}
                          :form {:email "nobody@example.com"}}))
  (assert (= (message-of asked) (message-of stranger))
          "an address with no account gets the same page — anything else is a way to ask this application who its {{plural}} are")
  (assert (empty? delivered) "and nothing was sent to it"))

(log/set-sinks! nil)
(os/rm sqlite-path)

(print "auth-test ok")
```)

(defn- auth-migration-path [spec]
  (string (spec :migrations-dir) "/" (spec :version)
          "_create_" (spec :table) ".janet"))

(defn- auth-substitutions
  "Every hole the built-in auth templates have, filled from the spec.
  An override that wants one of them gets it by calling this."
  [spec]
  (def fields (spec :fields))
  (def ff (filter identity (map form-field-source fields)))
  {:name (spec :name)
   :entity (spec :entity)
   :plural (spec :plural)
   :table (spec :table)
   :title (spec :title)
   :project (spec :project)
   :plugin (spec :plugin)
   :dir (spec :dir)
   :module-path (spec :module-path)
   :link-path (spec :link-path)
   # the plugin keyword as it is written in a :plugins list, and the
   # module the suite imports to register that manifest
   :driver (string/format "%q" (spec :driver))
   :driver-module (string (spec :driver))
   :migrations-dir (spec :migrations-dir)
   :version (spec :version)
   :field-keys (string/join (map |(string/format " %q" ($ :name)) fields) "")
   :schema-fields
   (block 3 (map |(string/format "%q %s" ($ :name) (node-source $)) fields))
   :columns (block 14 (map column-source fields))
   :inserts
   (block 21 (map |(string/format "%q (v %q)" ($ :name) ($ :name)) fields))
   :form-fields (block 15 ff)
   :sample
   (string/join (map (fn [f] (string/format " %q %s"
                                            (f :name)
                                            (get (field-type (f :type)) :sample)))
                     fields)
                "")})

(def auth-template-entries
  ``The built-in auth template, as data: one entry per file, each with
  the `:key` a project override is named after, a `:path` and a pure
  `:render`.``
  [{:key :auth
    :path (fn [s] (string (s :module-path) ".janet"))
    :render (fn [s] (template/render auth-template (auth-substitutions s)))}
   {:key :migration
    :path auth-migration-path
    :render (fn [s] (template/render auth-migration-template
                                     (auth-substitutions s)))}
   {:key :test
    :path (fn [s] (string (s :test-dir) "/auth-test.janet"))
    :render (fn [s] (template/render auth-test-template
                                     (auth-substitutions s)))}])

(defn auth-templates
  "The auth template to render: the built-in entries with the project's
  overrides applied."
  [&opt dir]
  (default dir auth-override-dir)
  (map |(override $ dir) auth-template-entries))

(def- auth-flags-with-values
  {"--table" :table "--plural" :plural "--dir" :dir
   "--migrations-dir" :migrations-dir "--test-dir" :test-dir
   "--project" :project "--version" :version
   "--driver" :driver "--link-path" :link-path})

(defn- parse-auth-args [args]
  (def opts @{})
  (def fields @[])
  (var name nil)
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (cond
      (in auth-flags-with-values a)
      (do (when (>= (inc i) (length args)) (errorf "%s expects a value" a))
          (put opts (in auth-flags-with-values a) (args (inc i)))
          (+= i 2))
      (= "--force" a) (do (put opts :force true) (++ i))
      (= "--dry-run" a) (do (put opts :dry-run true) (++ i))
      # accepted and inert: this generator never asks anything, so the
      # same command already runs in CI. The flag is here so that a
      # script written for `make resource` does not fall over on it
      (= "--no-input" a) (++ i)
      (string/has-prefix? "--" a) (errorf "void make auth: unknown flag %q" a)
      (nil? name) (do (set name a) (++ i))
      (do (array/push fields (parse-field a)) (++ i))))
  (when (opts :driver) (put opts :driver (keyword (string/trim (opts :driver) ":"))))
  [name fields opts])

# -- what the generator did not do ---------------------------------------
#
# `make` writes new files and edits none (see the module header), and
# the whole cost of that decision falls here: everything the scaffold
# *made necessary* in a file somebody has already edited has to be
# said, in full, in one place, or it becomes folklore — a paste
# remembered from the last project, and an application that boots into
# a page whose script the browser refuses with nothing in the terminal
# to say so. examples/hub found all three of these the expensive way
# (ROADMAP 6.6), which is why they are printed rather than assumed.

(def driver-dependencies
  ``The jpm dependency a driver's *library* comes from, by driver. Only
  sqlite has one: void/db-postgres and void/db-mysql open libpq and
  libmysqlclient through `ffi/` at run time, so nothing has to be
  installed for the module to load (ADR-0011).

  The void bundle deliberately does not carry janet-lang/sqlite3
  (ADR-0020): void/db-sqlite is a plugin an application composes, so
  the application declares it. The suite this generator writes boots
  that driver — so on a tree that has only void, the generated suite
  fails on its first import, with the driver's own (good) message and
  no hint that a generator caused it.``
  {:void/db-sqlite "https://github.com/janet-lang/sqlite3.git"})

(defn auth-report
  ``The lines `void make auth` prints after it has written its files:
  the three edits it did not make, in the order they have to happen.
  A pure function of the spec, so a test can read what a person is
  told rather than only what was written to disk.``
  [spec]
  (def out @[])
  (defn say [& parts] (array/push out (string ;parts)))
  (def dep (get driver-dependencies (spec :driver)))

  (say "  none of the three edits below was made for you: `void make` writes")
  (say "  new files and never rewrites a file you have edited — a generator")
  (say "  that does is one nobody dares run twice. They are printed instead,")
  (say "  in the order they have to happen.")

  (var step 0)
  (defn heading [& parts]
    (++ step)
    (say)
    (say "  " step ". " ;parts))

  (when dep
    (heading "project.janet — :dependencies")
    (say)
    (say "       " (string/format "%q" dep))
    (say)
    (say "     " (string/format "%q" (spec :driver)) " is a plugin an application composes, so the")
    (say "     application installs its library: the void bundle leaves it out on")
    (say "     purpose (ADR-0011). Without this line, on a tree that has only")
    (say "     void, " (spec :test-dir) "/auth-test.janet fails on its first import."))

  (def composition
    [[(string ":" (spec :plugin)) "the routes, the entity and the pages"]
     [(string ":void/db " (string/format "%q" (spec :driver)))
      "the entity layer and a driver, if not there yet"]
     [":void/crypto" "every hash and every code is minted here (ADR-0022)"]
     [":void/auth :void/auth-http :void/auth-db"
      "the identity, the session and the stores"]
     [":void/security" "the CSRF token the forms already carry"]
     [":void/mail :void/mail-auth" "what gets a link to the person"]])
  (def width (max ;(map |(length (first $)) composition)))
  (heading "main.janet — :plugins")
  (say)
  (each [names doc] composition
    (say "       " names (string/repeat " " (- width (length names))) "  " doc))

  (heading "config/dev.janet (or default.janet)")
  (say)
  (say "       {:http {:session {:enabled true}}")
  (say "        :void/auth-user-store {:impl :auth.db/users}")
  (say "        :void/auth-token-store {:impl :auth.db/tokens}")
  (say "        :void/auth-challenge-store {:impl :auth.db/challenges}")
  (say "        :auth-db {:users {:table " (string/format "%q" (spec :table))
       " :subject-kind " (string/format "%q" (spec :name)))
  (say "                          :email-column \"email\"")
  (say "                          :password-column \"password_hash\"")
  (say "                          :claims-columns [\"email\"]}}")
  (say "        :auth-http {:unauthenticated :redirect :login-path \"/login\"}")
  (say "        :mail-auth {:link-path " (string/format "%q" (spec :link-path)) "}")
  (say "        :mail {:transport :file :base-url \"http://localhost:8080\"")
  (say "               :from \"" (spec :project) " <no-reply@" (spec :project) ".example>\"}")
  (say "        :security {:csp {:policy {:default-src [:self]")
  (say "                                  :script-src [:self \"https://unpkg.com\"]")
  (say "                                  :base-uri [:self]")
  (say "                                  :form-action [:self]")
  (say "                                  :frame-ancestors [:none]")
  (say "                                  :object-src [:none]")
  (say "                                  :img-src [:self \"data:\"]}}}}")
  (say)
  (say "     The last key is there because this generator put :void/security in")
  (say "     the composition above, and its default policy is `default-src")
  (say "     'self'` — which refuses the htmx `void new` loads from unpkg. The")
  (say "     browser says so in its console and nowhere else, so the line is")
  (say "     printed here rather than found later. `:policy` replaces the")
  (say "     defaults rather than merging into them (half a policy is a")
  (say "     different policy), which is why the whole of it is written out;")
  (say "     serve htmx from your own assets and `:script-src [:self]` is the")
  (say "     only line that changes.")

  (say)
  (say "  a challenge nobody delivered is an error (ADR-0023 §7): without")
  (say "  :void/mail-auth — or a :void.auth/deliver of your own — registering")
  (say "  and resetting raise rather than mail nothing.")
  (say)
  (say "  then:")
  (say)
  (when dep (say "    jpm --local deps         # the driver's library"))
  (say "    void db migrate")
  (say "    void dev                 # /register")
  (say)
  (tuple ;out))

(defn auth
  ``The body of `void make auth [NAME] [field:type ...]`.

  NAME is what an account is called here — `user` by default. It
  becomes the entity, the table and the subject kind, so an identity
  reads `"user:42"` and `void/authz` can tell a person from a service
  token by looking at it. Extra `field:type` arguments are profile
  columns: they join the entity, the migration and the sign-up form,
  and everything else the scaffold declares is not the caller's to
  rename.

  Flags: `--table` / `--plural` (the pluralizer is a guess), `--dir`
  (where the module lands — the project root by default, beside
  app.janet), `--migrations-dir` / `--test-dir`, `--project` (the
  plugin's namespace), `--link-path` (what `[:mail-auth :link-path]`
  will point at), `--driver` (the one the generated suite boots on),
  `--version` (the migration's, for a reproducible run), `--force`
  (overwrite) and `--dry-run` (print instead of write).

  Returns the tuple of paths written — or, under `--dry-run`, the
  paths it would have written.``
  [& args]
  (def [name fields opts] (parse-auth-args args))
  (def spec-opts (merge {:project (project-name)} (table/to-struct opts)))
  (def spec
    (let [s (auth-spec name fields spec-opts)]
      # as in `resource`: a --force re-run lands on its own migration
      (if-let [v (and (opts :force) (nil? (opts :version))
                      (own-migration-version (s :migrations-dir) (s :table)))]
        (auth-spec name fields (merge spec-opts {:version v}))
        s)))
  (def entries (auth-templates))
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

  (print)
  (each line (auth-report spec) (print line))
  (tuple ;(map |($ :path) planned)))

# -- dispatch ------------------------------------------------------------

(def kinds
  "What `void make` can make. The table is the reason a third entry is
  a line rather than a rewrite of the dispatcher."
  {"resource" resource
   "auth" auth})

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
