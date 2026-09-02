(import ../test-support/paths)
(import void/cli/make :as make)
(import void/cli/prompt :as prompt)
(import void/cli :as cli)
# the composition the generated resource joins: importing a plugin's
# module is what registers its manifest for a keyword :plugins entry
(import void/http)
(import void/html)
(import void/htmx)
(import void/db)
(import void/core/plugin :as plugin)
(import void/core/system :as system)

(def fake-driver
  ``void/db's pool declares a dependency on the :void/db-driver
  interface, so the *graph* needs a provider even though nothing here
  starts one — `bootstrap-app` runs phases 1-5. Declaring one is
  cheaper, and more honest, than pulling a real engine into the CLI's
  suite.``
  (plugin/manifest 'test/driver
    :components [(system/component :test/driver
                   :provides [:void/db-driver]
                   :start (fn [&] (error "the make-test driver is never started")))]))

# `void make resource` writes four projections of one declaration
# (void/cli/make). This suite checks the declaration is read correctly,
# that the four files are what the spec says, and — the part that
# matters — that the generated code *runs*: its module loads, its
# entity registers, and its own suite passes.

# work in a throwaway directory; jpm test runs with cwd = cli/
(def root (os/cwd))
(def sandbox (string root "/.tmp-make-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defn- parses? [path]
  (def p (parser/new))
  (parser/consume p (slurp path))
  (parser/eof p)
  (not= :error (parser/status p)))

# -- naming --------------------------------------------------------------

(assert (= "posts" (make/plural "post")) "the plain rule")
(assert (= "boxes" (make/plural "box")) "sibilants take -es")
(assert (= "categories" (make/plural "category")) "consonant + y takes -ies")
(assert (= "days" (make/plural "day")) "vowel + y does not")

(assert (= "blog-post" (make/kebab "BlogPost")) "pascal in")
(assert (= "blog-post" (make/kebab "blog_post")) "snake in")
(assert (= "BlogPost" (make/pascal "blog-post")) "and back out")
(assert (= "BlogPost" (make/pascal (make/kebab "BlogPost"))) "round-trip")
(assert (= "blog_post" (make/snake "BlogPost")) "column spelling")

# -- fields --------------------------------------------------------------

(assert (deep= {:name :title :type :string :optional? false}
                (make/parse-field "title"))
        "a bare name is a string")
(assert (= :text ((make/parse-field "body:text") :type)) "a named type")
(assert ((make/parse-field "votes:int?") :optional?) "a trailing ? is optional")
(assert (= :votes ((make/parse-field "votes:int?") :name))
        "and is not part of the name")

(def ref-field (make/parse-field "author:ref:Author"))
(assert (= :author-id (ref-field :name)) "a ref names the column, not the relation")
(assert (= :author (ref-field :rel)) "and the relation, not the column")
(assert (= :Author (ref-field :entity)) "the entity it belongs to")
(assert (= "authors" (ref-field :table)) "the table it points at")
(assert (= :author-id ((make/parse-field "author-id:ref:Author") :name))
        "a name that already ends in -id is left alone")

(assert (not (first (protect (make/parse-field "x:nosuchtype"))))
        "an unknown type names the ones that exist")
(assert (not (first (protect (make/parse-field "author:ref"))))
        "a ref without an entity is refused")
(assert ((make/parse-field "author:ref:Author?") :optional?)
        "a ? means the same thing wherever it is written")
(assert (= :Author ((make/parse-field "author:ref:Author?") :entity))
        "and is not part of the entity it names")

(assert (not (first (protect (make/resource-spec "Bad_Name!" []))))
        "a name that cannot be a plugin keyword is refused once, by name")

# -- the spec ------------------------------------------------------------

(def spec (make/resource-spec "BlogPost" [(make/parse-field "title")]
                              {:project "demo" :version "20260101000000"}))
(assert (= "BlogPost" (spec :entity)) "the entity binding")
(assert (= "blog-posts" (spec :plural)) "the plural")
(assert (= "blog_posts" (spec :table)) "the table")
(assert (= "demo/blog-posts" (spec :plugin)) "the plugin name")

(def renamed (make/resource-spec "BlogPost" [(make/parse-field "title")]
                                 {:project "demo" :table "articles"
                                  :plural "articles"}))
(assert (= "articles" (renamed :table)) "--table wins over the pluralizer")
(assert (= "demo/articles" (renamed :plugin)) "--plural too")

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)
  (spit "project.janet" "(declare-project\n  :name \"demo\"\n  :version \"0.1.0\")\n")
  (assert (= "demo" (make/project-name))
          "the plugin namespace is read from project.janet")

  # -- the files -----------------------------------------------------------

  (def written
    (with-dyns [prompt/interactive-dyn false]
      (make/resource "Article" "title:string" "body:text" "votes:int?"
                     "email:email" "--version" "20260101000000")))
  (assert (deep= ["resources/articles.janet"
                  "db/migrations/20260101000000_create_articles.janet"
                  "test/articles-test.janet"]
                 (tuple ;(map string written)))
          "one file per template entry, where the spec says")
  (each f written (assert (parses? f) (string f " parses")))

  (def module (slurp "resources/articles.janet"))
  (assert (string/find "(db/defentity Article" module) "the entity is declared")
  (assert (string/find ":db/table \"articles\"" module) "with its table")
  (assert (string/find "[:optional [:int" module) "an optional field is optional")
  (assert (string/find ":format :email" module) "an email field is format-checked")
  (assert (string/find "{:control :textarea}" module) "a text field gets a textarea")
  (assert (string/find "(schema/select Article" module)
          "the form schema is a projection of the entity, not a copy")

  (def migration (slurp "db/migrations/20260101000000_create_articles.janet"))
  (assert (string/find ":create-table \"articles\"" migration) "the table is created")
  (assert (string/find "[:votes :int {:null true}]" migration)
          "an optional field is a nullable column")
  (assert (string/find ":unique true" migration) "and a unique one is unique")

  # -- nothing is clobbered ------------------------------------------------

  (assert (not (first (protect
                        (with-dyns [prompt/interactive-dyn false]
                          (make/resource "Article" "title:string")))))
          "an existing file is not overwritten")

  (with-dyns [prompt/interactive-dyn false]
    (make/resource "Article" "title:string" "--force" "--version" "20260101000000"))
  (assert (not (string/find "{:control :textarea}" (slurp "resources/articles.janet")))
          "--force insists, and rewrites from the new spec (no text field, no textarea)")

  # a --force re-run without --version adopts the earlier migration's
  # timestamp: one CREATE TABLE, not an orphaned pair `void db migrate`
  # trips over
  (with-dyns [prompt/interactive-dyn false]
    (make/resource "Article" "title:string" "--force"))
  (def article-migrations
    (filter |(string/has-suffix? "_create_articles.janet" $)
            (os/dir "db/migrations")))
  (assert (deep= @["20260101000000_create_articles.janet"] article-migrations)
          "--force lands on its own earlier migration file")

  # -- flag values are checked before anything is written ------------------

  (each [flag value] [["--dir" "../escaped"] ["--dir" "/tmp/escaped"]
                      ["--migrations-dir" "db/../../escaped"]
                      ["--test-dir" "/escaped"]]
    (assert (not (first (protect
                          (with-dyns [prompt/interactive-dyn false]
                            (make/resource "Leak" "title:string" flag value)))))
            (string flag " " value " is refused — a generator must not write outside the project"))
    (assert (not (os/stat "../escaped")) "and nothing landed outside"))
  (assert (not (first (protect (make/resource-spec "post" [] {:plural "../pwn"}))))
          "--plural must be a word, not a path")
  (assert (not (first (protect (make/resource-spec "post" [] {:table "../pwn"}))))
          "--table too")
  (assert (not (first (protect (make/resource-spec "post" [] {:version "../v"}))))
          "--version must be a migration timestamp")

  # -- --dry-run writes nothing --------------------------------------------

  (def out @"")
  (def planned
    (with-dyns [:out out prompt/interactive-dyn false]
      (make/resource "Tag" "label:string" "--dry-run")))
  (assert (not (os/stat "resources/tags.janet")) "--dry-run writes no file")
  (assert (string/find "(db/defentity Tag" (string out))
          "and prints what it would have written")
  (assert (= 3 (length planned)) "for every entry of the template")

  # -- the project's own template wins -------------------------------------

  (os/mkdir "templates")
  (os/mkdir "templates/resource")
  (spit "templates/resource/migration.janet"
        "(defn render [spec] (string \"# \" (spec :table) \" by hand\\n\"))\n")
  (with-dyns [prompt/interactive-dyn false]
    (make/resource "Tag" "label:string" "--version" "20260101000100"))
  (assert (= "# tags by hand\n"
             (string (slurp "db/migrations/20260101000100_create_tags.janet")))
          "a project override replaces the built-in template")
  (assert (string/find "(db/defentity Tag" (slurp "resources/tags.janet"))
          "and only the entry it overrides")

  (spit "templates/resource/migration.janet" "(def render 42)\n")
  (assert (not (first (protect (make/templates))))
          "an override that is not a render function says so")
  (os/rm "templates/resource/migration.janet")

  # -- the generated suite runs --------------------------------------------
  #
  # The point of generating a suite is that it passes on the code that
  # was generated with it: the entity loads, the schemas agree with the
  # migration and the routes are declared under their policy names.
  (def [suite-ok suite-err] (protect (dofile "test/articles-test.janet")))
  (assert suite-ok
          (string "the generated suite passes against the generated resource: "
                  (if (string? suite-err) suite-err (describe suite-err))))

  # -- and the resource is a plugin the CLI can boot -----------------------

  (cli/add-project-paths! (os/cwd))
  (def boot (cli/bootstrap-app {:plugins [:void/http :void/html :void/htmx
                                          :void/db fake-driver :demo/articles]}
                               :test))
  (def table ((get-in (require "void/http") ['routes-table :value])))
  (each name [:articles/index :articles/new :articles/create :articles/show
              :articles/edit :articles/update :articles/destroy]
    (assert (get-in table [:by-name name])
            (string "route " name " reaches the table")))
  (assert (= "/articles/new" (get-in table [:by-name :articles/new :pattern]))
          "a literal segment keeps its own route"))

(print "make-test ok")
