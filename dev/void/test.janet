### void/test — test support (SPEC.md §4).
###
### Fixtures are components: bring up just the subset of the system a
### test needs (:only — the listed components plus their transitive
### deps) and swap real components for stubs by re-registering the
### same :key (:components override). Factories come straight from the
### schema layer through the :generator projection — one declaration
### feeds validation, docs and test data alike (ADR-0008). `snapshot`
### stores golden renderings under test/snapshots (hiccup views,
### ROADMAP 1.2).

(import void/core/system :as system)
(import void/core/plugin :as plugin)
(import ./dev/generate :as gen)

(def- allowed-opts
  {:plugins true :profile true :config true :only true :components true})

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

(defn- deps-closure [sys ks]
  (def needed @{})
  (defn visit [k]
    (unless (in needed k)
      (unless (get-in sys [:components k])
        (errorf "test/start!: unknown component %q in :only (components: %s)"
                k (names-str (keys (sys :components)))))
      (put needed k true)
      (each rk (values (get-in sys [:resolution k] {}))
        (visit rk))))
  (each k ks (visit k))
  needed)

(defn start!
  ``Bootstrap and start a test system.

  Options — plugin/bootstrap's :plugins/:profile/:config (the profile
  defaults to :test) plus:
    :components  extra component definitions; one with an existing
                 :key replaces the real component — the stub/fixture
                 mechanism
    :only        component keys to start; their transitive deps come
                 along, everything else is left out of the graph

  The bootstrap is untracked (it never becomes the REPL tools' default
  subject). Returns the boot value.``
  [opts]
  (eachk k opts
    (unless (in allowed-opts k)
      (errorf "test/start!: unknown option %q (allowed: %s)"
              k (names-str (keys allowed-opts)))))
  (def boot-opts
    (tabseq [k :in [:plugins :config] :when (get opts k)] k (opts k)))
  (put boot-opts :profile (get opts :profile :test))
  (def boot (plugin/bootstrap boot-opts true))
  (def sys (boot :system))
  (def comps (merge-into @{} (sys :components)))
  (each c (get opts :components [])
    (put comps (c :key) c))
  (def cfg (sys :config))
  (var sub (system/init comps cfg))
  (when-let [only (get opts :only)]
    (def needed (deps-closure sub only))
    (set sub (system/init (filter |(in needed ($ :key)) (values comps)) cfg)))
  (put boot :system sub)
  (system/start sub)
  (put boot :phase :ready)
  boot)

(defn stop!
  "Stop a test system (reverse order, per-component timeout in
  seconds, default 5). Returns the boot value."
  [boot &opt timeout]
  (default timeout 5)
  (system/stop (boot :system) timeout)
  (put boot :phase :stopped)
  boot)

(defmacro with-system
  ``Run body with a started test system, always stopping it:

      (test/with-system [boot {:plugins [my/plugin] :only [:db/pool]}]
        (def pool (system/instance (boot :system) :db/pool))
        ...)``
  [binding & body]
  (unless (and (indexed? binding) (= 2 (length binding)))
    (error "with-system expects [binding-symbol options] and a body"))
  (def [sym opts] binding)
  ~(do
     (def ,sym (,start! ,opts))
     (defer (,stop! ,sym)
       ,;body)))

(defn generate
  "Generate a sample value for a schema — see void/dev/generate."
  [sch &opt opts]
  (gen/generate sch opts))

(defn snapshot
  ``Compare the string rendering of `actual` against the stored
  snapshot `dir`/`name`.snap (dir defaults to "test/snapshots",
  relative to the package root jpm test runs from — hiccup snapshot
  testing, ROADMAP 1.2, but any stringable value works).

  A missing snapshot is created and the call succeeds — review and
  commit it. On a mismatch the call throws with both versions; run
  with VOID_SNAPSHOT_UPDATE=1 to rewrite the stored snapshots
  instead. Returns :created, :updated or :matched.``
  [name actual &opt dir]
  (default dir "test/snapshots")
  (def path (string dir "/" name ".snap"))
  (def s (string actual))
  (defn write! []
    (var acc "")
    (each part (string/split "/" dir)
      (set acc (if (empty? acc) part (string acc "/" part)))
      (unless (or (empty? acc) (= "." acc))
        (os/mkdir acc)))
    (spit path s))
  (cond
    (nil? (os/stat path))
    (do (write!) :created)

    (= (string (slurp path)) s)
    :matched

    (os/getenv "VOID_SNAPSHOT_UPDATE")
    (do (write!) :updated)

    (errorf "snapshot %q differs from %s:\n--- stored ---\n%s\n--- actual ---\n%s\n(run with VOID_SNAPSHOT_UPDATE=1 to update)"
            name path (slurp path) s)))

(defn factory
  ``A sample value for a map schema with explicit overrides on top:

      (test/factory User :email "fixed@example.com")

  Returns a mutable table. Overrides are the escape hatch for fields
  the generator cannot invent (:pred, :pattern ...).``
  [sch & kvs]
  (when (odd? (length kvs))
    (error "factory: expected key-value override pairs"))
  (def base (generate sch))
  (if (empty? kvs)
    base
    (do
      (unless (dictionary? base)
        (errorf "factory overrides need a map schema, generated %q" base))
      (merge-into (if (table? base) base (merge-into @{} base))
                  (table ;kvs)))))
