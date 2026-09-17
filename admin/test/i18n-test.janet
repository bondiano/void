### The back office has words of its own, and one claim about them:
### English out of the box, translated whole by a dictionary, and
### `void/admin` has no edge to `void/i18n` either way.
###
### Both halves are checked here against the same pages: once in a
### composition with no catalog at all — the fallback table is what the
### operator reads — and once with void/i18n and a Russian dictionary
### that overrides keys this package never told it about.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/test :as test)
(import void/db :as db)
(import void/admin :as admin)
(import void/admin/text :as admin-text)
(import void/authz :as authz)

(log/set-level! nil :error)

(db/defentity Note
  {:id [:int {:db/pk true :db/type "integer"}]
   # :label is an annotation the schema carries and validation never
   # reads — a keyword one is a translation key, and the words belong
   # to whoever wrote the schema
   :title [:string {:min 1 :max 60 :db/type "text" :label :demo/title}]
   :done [:boolean {:db/type "integer"}]}
  :db/table "notes")

(admin/defresource-admin notes Note
  :title "Notes"
  :list [:id :title :done]
  :form [:title :done]
  :search [:title]
  :filters [:done])

(authz/defpolicy :staff "Everybody, in this test." [_] true)

(def db-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-admin-i18n-" (os/time) ".sqlite3"))

(def base-plugins
  ["void/http/init" "void/html/init" "void/htmx/init"
   "void/db/init" "void/db-sqlite/init" "void/db/http"
   "void/authz/init" "void/authz/http" "void/admin/init"])

(def ru
  ``A dictionary for keys this package never told void/i18n about: the
  admin's own words are `:void.admin/...`, and a key is the whole of
  the declaration the catalog side needs.``
  (plugin/manifest 'test/ru
    :version "0.1.0"
    :requires {:void/i18n ">=0.0.1"}
    :contributes
    {:void.i18n/messages
     [{:name :test/ru :locale :ru
       :messages {:void.admin/save "Сохранить"
                  :void.admin/cancel "Отмена"
                  :void.admin/search "Поиск"
                  :void.admin/nothing-here "Здесь пусто."
                  :void.admin/new-one "Новая {singular}"
                  :demo/title "Заголовок"}}]}))

(defn- seed!
  {:params [] :ret {:rows @[{:keyword :any}] :count :number}}
  "Recreate the notes table fresh, empty — the pages under test read
  it through :void.admin/nothing-here, not through fixture rows."
  []
  (db/execute-sql "DROP TABLE IF EXISTS notes" [] {:kind :write :prepared false})
  (db/execute-sql
    (string "CREATE TABLE notes (id integer primary key autoincrement, "
            "title text not null, done integer not null default 0)")
    [] {:kind :write :prepared false}))

(defn- opts
  {:params [@[:any] (or {:any :any} :nil)]
   :ret {:plugins @[:any] :profile :keyword :config {:any :any} :only @[:keyword]}}
  "The boot options for one composition: the given plugins plus,
  when `i18n-slice` is given, its [:i18n ...] config slice."
  [plugins i18n-slice]
  {:plugins plugins
   :profile :test
   :config {:env @{}
            :cli (merge {:http {:port 0}
                         :db-sqlite {:path db-path}
                         :admin {:access :staff}}
                        (if i18n-slice {:i18n i18n-slice} {}))}
   :only [:http/kernel :db/pool :authz/registry]})

# -- no catalog at all ---------------------------------------------------

(def plain (test/start! (opts base-plugins nil)))
(defer (test/stop! plain)
  (seed!)
  (def c (test/client plain))
  (def list-page (test/text (test/inject c {:uri "/admin/notes"})))
  (assert (string/find "Nothing here." list-page)
          "with nothing bound, the package's own table is what the page reads")
  (assert (string/find ">Search<" list-page))
  (assert (not (string/find "void.admin/" list-page))
          "and never a keyword name — a fallback that printed keys would be no fallback")

  (def form (test/text (test/inject c {:uri "/admin/notes/new"})))
  (assert (string/find ">Save<" form))
  (assert (string/find "New Note" form))
  (assert (string/find ">Title<" form)
          "a :label nobody can translate falls back to the field's own name"))

# -- the same pages, with a catalog --------------------------------------

(def translated
  (test/start! (opts [;base-plugins "void/i18n/init" ru]
                     {:locales [:en :ru] :default :en})))

(defer (test/stop! translated)
  (seed!)
  (def c (test/client translated))
  (defn page
    {:params [:string :string] :ret :string}
    "The rendered body of `uri`, requested in the given Accept-Language."
    [uri lang]
    (test/text (test/inject c {:uri uri :headers {"accept-language" lang}})))

  (def list-ru (page "/admin/notes" "ru"))
  (assert (string/find "Здесь пусто." list-ru)
          "a dictionary translates the back office without this package knowing")
  (assert (string/find ">Поиск<" list-ru))
  (assert (string/find "Новая Note" list-ru)
          "a parameter rides through the translated sentence, not around it")

  (def form-ru (page "/admin/notes/new" "ru"))
  (assert (string/find ">Сохранить<" form-ru))
  (assert (string/find ">Отмена<" form-ru))
  (assert (string/find ">Заголовок<" form-ru)
          "the schema's own :label keyword is translated too, by the catalog")

  # a key the dictionary does not carry keeps the package's English:
  # a missing translation is a word, not a keyword name
  (assert (string/find ">Filter<" list-ru))

  (def list-en (page "/admin/notes" "en"))
  (assert (string/find "Nothing here." list-en)
          "and the default locale is the English the table already held")
  (assert (string/find ">Title<" (page "/admin/notes/new" "en"))))

# -- the table is the only place the words live --------------------------

(assert (get admin-text/en :void.admin/save))
(assert (nil? (get admin-text/en :void.admin/nope)))
(assert (= "void.admin/nope" (admin-text/t :void.admin/nope))
        "a key with no entry renders as its own name — visible, never a crash")

(os/rm db-path)
(print "admin i18n-test ok")
