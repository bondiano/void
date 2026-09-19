### void/cli/make/spec — what a generator's declaration is made of.
###
### Naming (a resource is written `BlogPost` and read as `blog-post`,
### `blog_posts`, `BlogPost`, "Blog post"), the field types every
### generated file is a projection of, the checks a flag value gets
### before it becomes a path or a table name, and the source-text
### projections of one field. Shared because `make resource` and `make
### auth` differ in what they generate and not at all in what a field
### is.

# -- naming --------------------------------------------------------------

(def- vowels "aeiou")

(defn plural
  {:params [:string] :ret :string}
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
  {:params [:string] :ret :string}
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
  {:params [:string] :ret :string}
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
  {:params [:string] :ret :string}
  "Column and table spelling: \"blog-post\" -> \"blog_post\"."
  [name]
  (string/replace-all "-" "_" (kebab name)))

(defn title
  {:params [:string] :ret :string}
  "Display spelling of a name: \"blog-post\" -> \"Blog post\"."
  [name]
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
#
# There used to be an eleventh column, `:db/type`: the SQL the DDL
# column becomes ("text", "integer"), re-typed here from
# `void/db/builder`'s `ansi-types` because the CLI needs only the
# kernel and cannot import void/db to ask. It is gone, and the entity
# now declares `:db/type :text` — the builder's own portable keyword,
# the same value `:column` already was. The one reader of it,
# `void/db/erd`, maps it through `ansi-types`, which is where that
# table lives and where a dialect's override of it is in scope.

(def field-types
  ``The types `name:type` accepts, in the order the interactive picker
  offers them. One row per type, and every key of the row is a
  projection some generated file needs: `:type` and `:props` are the
  schema node the entity declares, `:column` is the builder's portable
  DDL type — which the migration writes and the entity declares as its
  `:db/type` — `:control` overrides the form control the schema would
  imply, `:unique` is a constraint the migration writes, and `:sample`
  is a valid value for the generated suite.``
  [{:label "string" :value :string :doc "short text, one input"
    :column :text :sample `"a name"`
    :props `{:min 1 :max 120}` :type :string}
   {:label "text" :value :text :doc "long text, a textarea"
    :column :text :sample `"a longer body"`
    :props `{:min 1 :max 4000}` :type :string :control :textarea}
   {:label "int" :value :int :doc "whole number"
    :column :int :sample "42" :props nil :type :int}
   {:label "float" :value :float :doc "fractional number"
    :column :real :sample "1.5" :props nil :type :number}
   {:label "bool" :value :bool :doc "true or false"
    :column :bool :sample "true" :props nil :type :boolean}
   {:label "email" :value :email :doc "a string, format-checked and unique"
    :column :text :sample `"ada@example.com"`
    :props `{:format :email :db/unique true}` :type :string :unique true}
   {:label "uuid" :value :uuid :doc "a uuid"
    :column :uuid :sample `"3f2504e0-4f89-41d3-9a0c-0305e82c3301"` :props nil :type :uuid}
   {:label "date" :value :date :doc "a calendar date, as text"
    :column :date :sample `"2026-01-31"` :props nil :type :string}
   {:label "datetime" :value :datetime :doc "a timestamp, as text"
    :column :timestamp :sample `"2026-01-31T09:00:00Z"` :props nil :type :string}
   {:label "ref" :value :ref :doc "belongs-to another entity (name:ref:Author)"
    :column :int :sample "1" :props nil :type :int}])

(def- type-by-value (tabseq [t :in field-types] (t :value) t))

(defn field-type
  {:params [:keyword]
   :ret {:label :string :value :keyword :doc :string :column :keyword
         :sample :string :props :string? :type :keyword
         :control :keyword? :unique :boolean?}
   :throws [:string]}
  "The type row `name:type` names, by its :value — the schema node,
  the DDL column, the form control and a sample value it projects to."
  [name]
  (or (in type-by-value name)
      (errorf "unknown field type %q — one of %s"
              name (string/join (map |(string ($ :label)) field-types) ", "))))

(defn parse-field
  {:params [:string]
   :ret {:name :keyword :type :keyword :optional? :boolean
         :entity :keyword? :rel :keyword? :table :string?}
   :throws [:string]}
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

(defn check-word
  {:params [:string :string] :ret :string :throws [:string]}
  "A flag value that becomes an identifier — a table, a plural, a
  project name."
  [flag value]
  (unless (peg/match '(* (range "az") (any (+ (range "az") (range "09") "-" "_")) -1)
                     (string value))
    (errorf "%s %q must be a word: a lowercase letter, then letters, digits, - or _"
            flag value))
  value)

(defn check-subpath
  {:params [:string :string] :ret :string :throws [:string]}
  "A flag value that becomes a directory — inside the project, always."
  [flag value]
  (def s (string value))
  (when (or (empty? s)
            (string/has-prefix? "/" s)
            (some |(or (empty? $) (= ".." $)) (string/split "/" s)))
    (errorf "%s %q must be a relative path inside the project (no leading /, no .. and no empty segments)"
            flag s))
  s)

(defn check-version
  {:params [:string] :ret :string :throws [:string]}
  "A flag value that becomes a migration version: digits, like the
  timestamp `timestamp` below generates."
  [value]
  (unless (peg/match '(* (some (range "09")) -1) (string value))
    (errorf "--version %q must be digits — a migration timestamp like 20260101120000"
            value))
  value)

(defn check-spec-opts
  {:params [{:plural :string? :table :string? :project :string?
             :version :string? :migrations-dir :string? :test-dir :string?
             & r}]
   :ret {:plural :string? :table :string? :project :string?
         :version :string? :migrations-dir :string? :test-dir :string?
         & r}
   :throws [:string]}
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


(defn timestamp
  {:params [] :ret :string}
  "Now, as the fourteen digits a migration's filename sorts by."
  []
  (def d (os/date (os/time) true))
  (string/format "%04d%02d%02d%02d%02d%02d"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

# -- rendering helpers ---------------------------------------------------

(defn node-source
  {:params [{:name :keyword :type :keyword :optional? :boolean
             :entity :keyword? :rel :keyword? :table :string?}]
   :ret :string
   :throws [:string]}
  "The schema node one field declares, as source text."
  [f]
  (def spec (field-type (f :type)))
  (def props
    (cond
      (= :ref (f :type)) (string/format "{:db/fk %q :db/type %q}"
                                        (f :entity) (spec :column))
      (nil? (spec :props)) (string/format "{:db/type %q}" (spec :column))
      (string (string/slice (spec :props) 0 -2)
              (string/format " :db/type %q}" (spec :column)))))
  (def core (string/format "[%q %s]" (spec :type) props))
  (if (f :optional?) (string/format "[:optional %s]" core) core))

(defn column-source
  {:params [{:name :keyword :type :keyword :optional? :boolean
             :entity :keyword? :rel :keyword? :table :string?}]
   :ret :string
   :throws [:string]}
  "The DDL column one field creates, as source text."
  [f]
  (def spec (field-type (f :type)))
  (def opts @[])
  (array/push opts (string/format ":null %s" (if (f :optional?) "true" "false")))
  (when (spec :unique) (array/push opts ":unique true"))
  (when (= :ref (f :type))
    (array/push opts (string/format ":refs [:%s :id] :on-delete :cascade" (f :table))))
  (string/format "[%q %q {%s}]" (f :name) (spec :column) (string/join opts " ")))

(defn form-field-source
  {:params [{:name :keyword :type :keyword :optional? :boolean
             :entity :keyword? :rel :keyword? :table :string?}]
   :ret :string?
   :throws [:string]}
  "The `:fields` override of one field in the form declaration, or nil
  when the control the schema implies is already right."
  [f]
  (when-let [c (get (field-type (f :type)) :control)]
    (string/format "%q {:control %q}" (f :name) c)))

(defn indent
  {:params [:number [:string]] :ret :string}
  "Join `lines` with a newline and `n` spaces, so a block pasted into a
  template lines up under whatever indents it."
  [n lines]
  (def pad (string/repeat " " n))
  (string/join lines (string "\n" pad)))

(defn field-keys
  {:params [{:fields [{:name :keyword :type :keyword :optional? :boolean
                       :entity :keyword? :rel :keyword? :table :string?}]
             & r}]
   :ret :string}
  "Every field's name, quoted and space-joined — the schema's own key
  order, as source text."
  [spec]
  (string/join (map |(string/format "%q" ($ :name)) (spec :fields)) " "))

(defn form-fields
  {:params [{:fields [{:name :keyword :type :keyword :optional? :boolean
                       :entity :keyword? :rel :keyword? :table :string?}]
             & r}]
   :ret @[:string]
   :throws [:string]}
  "The `:fields` overrides the form declaration needs, one per field
  whose control the schema would get wrong."
  [spec]
  (filter identity (map form-field-source (spec :fields))))

(defn rels
  {:params [{:fields [{:name :keyword :type :keyword :optional? :boolean
                       :entity :keyword? :rel :keyword? :table :string?}]
             & r}]
   :ret @[{:name :keyword :type :keyword :optional? :boolean
           :entity :keyword? :rel :keyword? :table :string?}]}
  "The fields that are a belongs-to relation (name:ref:Entity)."
  [spec]
  (filter |(= :ref ($ :type)) (spec :fields)))

(defn sample-source
  {:params [{:fields [{:name :keyword :type :keyword :optional? :boolean
                       :entity :keyword? :rel :keyword? :table :string?}]
             & r}]
   :ret :string
   :throws [:string]}
  "Every field's name and a sample value, space-joined — a valid
  argument list a generated suite can call the entity with."
  [spec]
  (string/join
    (map (fn [f] (string/format "%q %s" (f :name) (get (field-type (f :type)) :sample)))
         (spec :fields))
    " "))

(defn display-field
  {:params [{:fields [{:name :keyword :type :keyword :optional? :boolean
                       :entity :keyword? :rel :keyword? :table :string?}]
             & r}]
   :ret (or {:name :keyword :type :keyword :optional? :boolean
             :entity :keyword? :rel :keyword? :table :string?}
            :nil)}
  "The field a list row shows. The first string-ish one, because a row
  of integers is a row nobody can read; the primary key when there is
  no such field."
  [spec]
  (or (find |(index-of ($ :type) [:string :text :email]) (spec :fields))
      (first (spec :fields))))

# -- the project -----------------------------------------------------------

(defn project-name
  {:params [:string?] :ret :string :throws [:string]}
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
