### void/cli/make/migration — `void make migration NAME`.
###
### This was `void db new`, a contribution of void/db, and it is here
### now for the reason the other generators are built in: writing a
### file into a project must not depend on that project booting. `void
### db new` had to bootstrap the application and open a connection pool
### — `:needs [:db/pool]` — to write an empty file, so the one command
### you reach for when the schema is wrong was the one the wrong schema
### could stop.
###
### What it gives up is the configured `[:db :migrations :dir]`: this
### writes to `db/migrations` unless `--dir` says otherwise, the same
### default `make resource` has always written its migration to without
### asking anyone.

(import ./spec :as f)
(import ./scaffold)

(def template
  ``An empty migration, as void/db reads one: a step returns what it
  wants run, and void/db/builder compiles the statement map for
  whichever engine is running — which is what keeps one migration file
  portable.``
  ``### {{slug}}
###
### A step returns what it wants run: a statement map (SQL as data —
### void/db/builder compiles the DDL for whichever engine is running),
### a raw SQL string for what the builder has no spelling for, or a
### tuple of either. `db` is imported for the steps that compute.
(import void/db :as db)

(defn up []
  # {:create-table "things"
  #  :columns [[:id :serial {:primary-key true}]
  #            [:name :text {:null false}]]}
  )

(defn down []
  # {:drop-table "things"}
  )
``)

(def entries
  "One file, and a project overrides it at templates/migration/step.janet."
  [{:key :step
    :path (fn [s] (string (s :migrations-dir) "/" (s :version) "_" (s :slug) ".janet"))
    :render (fn [s] (string/replace "{{slug}}" (s :slug) template))}])

(def override-dir
  "Where a project keeps its own migration template."
  "templates/migration")

(defn migration-spec
  {:params [:string (or {:migrations-dir :string? :version :string? & r} :nil)]
   :ret {:slug :string :migrations-dir :string :version :string}
   :throws [:string]}
  ``The value the template is a function of: a slug and a version.
  `name` is snake_cased the way every migration file in the tree is
  named, and it may arrive as several words — `void make migration add
  users index`, `add-users-index` and `add_users_index` are one file.``
  [name &opt opts]
  (default opts {})
  (def slug (f/snake (f/kebab (string/replace-all " " "-" (string name)))))
  (when (empty? slug)
    (error "a migration needs a name: void make migration add-users-index"))
  (f/check-spec-opts opts)
  {:slug slug
   :migrations-dir (get opts :migrations-dir "db/migrations")
   :version (or (get opts :version) (f/timestamp))})

(def command
  {:name :make/migration
   :doc "Scaffold an empty migration file"
   :args ["NAME..."]
   :flags {"--migrations-dir" {:key :migrations-dir :doc "default: db/migrations"}
           "--version" {:key :version :doc "the migration's version, for a reproducible run"}
           "--force" {:key :force :type :bool :doc "overwrite what is there"}
           "--dry-run" {:key :dry-run :type :bool :doc "print instead of writing"}}})

(defn create
  {:params [{:migrations-dir :string? :version :string? :dry-run :boolean?
             :force :boolean? & r}
            :string]
   :ret [:string]
   :throws [:string]}
  ``The body of `void make migration NAME`. Returns the path written.
  Several words are one name, because `void make migration add users
  index` is what a reader types before they have thought about the
  file.``
  [opts & words]
  (def written
    (scaffold/run! (migration-spec (string/join words " ") (table/to-struct opts))
                   (scaffold/templates entries override-dir)
                   opts))
  (unless (opts :dry-run)
    (print)
    (print "  then: void db migrate"))
  written)
