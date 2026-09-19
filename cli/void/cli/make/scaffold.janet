### void/cli/make/scaffold — what every generator does with its plan.
###
### A generator's judgement is building the spec; everything after that
### was the same twenty-five lines in `make resource` and `make auth`,
### written twice: render each template entry, print instead of writing
### under `--dry-run`, refuse to clobber without `--force`, make the
### directories, write, and say what was written and where the override
### came from. `run!` is that, once.
###
### **Templates are data.** A generator's built-in set is a tuple of
### `{:key :path :render}` entries whose `:render` is a pure `(fn [spec]
### string)`. A project overrides one by dropping a Janet module at
### `templates/<kind>/<key>.janet` that defines `render` (and, if the
### file should land elsewhere, `path`). There is deliberately no second
### templating language: a project that wants its own layout writes
### Janet, which is what it is going to edit the output in anyway.

(defn override
  {:params [{:key :keyword :path (fn [:any] :string) :render (fn [:any] :string) & r} :string]
   :ret {:key :keyword :path (fn [:any] :string) :render (fn [:any] :string) & r}
   :throws [:string]}
  ``The project's replacement for one template entry, or the entry
  unchanged. An override is a Janet module at `templates/<kind>/<key>.janet`
  defining `render` — `(fn [spec] string)` — and optionally `path`. It
  is required, not evaluated in a sandbox: it is the project's own
  code, run by the project's own developer, the way `project.janet`
  is.``
  [entry dir]
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
  {:params [[{:key :keyword :path (fn [:any] :string) :render (fn [:any] :string) & r}]
            :string]
   :ret @[{:key :keyword :path (fn [:any] :string) :render (fn [:any] :string) & r}]
   :throws [:string]}
  "The entries to render: the built-in ones with the project's
  overrides from `dir` applied."
  [entries dir]
  (map |(override $ dir) entries))

(defn- ensure-dirs
  {:params [:string] :ret :nil}
  "Make every directory on `path` but its last part, as `mkdir -p`
  would."
  [path]
  (var cur "")
  (each part (drop -1 (string/split "/" path))
    (set cur (if (empty? cur) part (string cur "/" part)))
    (unless (os/stat cur) (os/mkdir cur))))

(defn own-migration-version
  {:params [:string :string] :ret :string?}
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

(defn specced
  {:params [(fn [:any] {:migrations-dir :string :table :string & r})
            {:force :any :version :any & r}]
   :ret {:migrations-dir :string :table :string & r}}
  ``Build the spec, then build it again with the version of the
  migration this generator wrote last time — which is what `--force`
  without an explicit `--version` has to mean, or the re-run leaves its
  own earlier CREATE TABLE orphaned beside a new one that the next
  `void db migrate` trips over. `build` is (fn [extra-opts] spec).``
  [build opts]
  (def s (build {}))
  (if-let [v (and (opts :force) (nil? (opts :version))
                  (own-migration-version (s :migrations-dir) (s :table)))]
    (build {:version v})
    s))

(defn run!
  {:params [:any
            [{:key :keyword :path (fn [:any] :string) :render (fn [:any] :string) & r}]
            {:dry-run :any :force :any & r}]
   :ret [:string]
   :throws [:string]}
  ``Render `entries` against `spec` and put the result where it goes.

  `--dry-run` prints every file to stdout instead, so the command
  composes with a pager and a diff; without `--force` a path that
  already exists stops the whole run before anything is written, since
  a generator that half-wrote is worse than one that refused.

  Returns the tuple of paths written — or, under `--dry-run`, the paths
  it would have written.``
  [spec entries opts]
  (def planned
    (seq [e :in entries]
      {:path ((e :path) spec) :body ((e :render) spec) :source (get e :source)}))
  (defn- via
    {:params [{:path :string :body :string :source :string? & r}] :ret :string}
    [p] (if (p :source) (string "  (via " (p :source) ")") ""))

  (if (opts :dry-run)
    (each p planned
      (print "# " (p :path) (via p))
      (print (p :body)))
    (do
      (unless (opts :force)
        (def clashes (filter |(os/stat ($ :path) :mode) planned))
        (unless (empty? clashes)
          (errorf "refusing to overwrite %s (pass --force)"
                  (string/join (map |($ :path) clashes) ", "))))
      (each p planned
        (ensure-dirs (p :path))
        (spit (p :path) (p :body))
        (print "  created " (p :path) (via p)))))
  (tuple ;(map |($ :path) planned)))
