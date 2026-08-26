### void/dev/watch — file watcher for the reloaded workflow (SPEC.md §4).
###
### A polling watcher (no native deps): snapshot the mtimes of every
### .janet file under the watched paths, and on change (1) re-evaluate
### the file into its existing module env table — same table, so
### symbol-resolved references pick up the new definitions (late
### binding, ADR-0002) — and (2) restart the stateful components of
### every plugin whose manifest :source is that file (the
### file->component map; `defplugin` records :source). Stateless code
### needs no restart: the env reload is the whole story.

(import void/core/system :as system)
(import void/core/plugin :as plugin)

# -- pure parts (testable without the component fiber) -------------------

(defn scan
  "Walk files/directories and snapshot every .janet file:
  @{realpath modified-time}. Hidden directories are skipped."
  [paths]
  (def out @{})
  (defn walk [p]
    (when-let [st (os/stat p)]
      (case (st :mode)
        :directory
        (each name (sorted (os/dir p))
          (unless (string/has-prefix? "." name)
            (walk (string p "/" name))))
        :file
        (when (string/has-suffix? ".janet" p)
          (put out (os/realpath p) (st :modified))))))
  (each p paths (walk p))
  out)

(defn changed
  "Files present in `new` whose mtime differs from `old` (new files
  count, deletions do not), sorted."
  [old new]
  (sorted (seq [[p t] :pairs new :when (not= t (get old p))] p)))

(defn- module-env
  "The module/cache env whose resolved path is `file` (compared by
  realpath), or nil when the file is not a loaded module."
  [file]
  (var found nil)
  (eachk key module/cache
    (when (and (nil? found) (string? key))
      (def [ok rp] (protect (os/realpath key)))
      (when (and ok (= rp file))
        (set found (in module/cache key)))))
  found)

(defn reload!
  "Re-evaluate `file` into its existing module env table. Returns
  :reloaded, or :skipped when the file is not a loaded module; eval
  errors propagate."
  [file]
  (if-let [env (module-env file)]
    (do (dofile file :env env) :reloaded)
    :skipped))

(defn affected-components
  "Component keys to restart after `file` changed: the components of
  every manifest in `boot` whose :source is this file, that hold state
  (:stop or :suspend) and are currently :running — in start order.
  Everything else is already covered by the env reload."
  [boot file]
  (def wanted @{})
  (each m (values (get boot :manifests {}))
    (def [ok rp] (protect (os/realpath (or (m :source) ""))))
    (when (and ok (= rp file))
      (each c (m :components)
        (when (or (c :stop) (c :suspend))
          (put wanted (c :key) true)))))
  (filter |(and (in wanted $)
                (= :running (get-in boot [:system :states $])))
          (get-in boot [:system :order] [])))

(defn apply-changes!
  "Reload every changed file, then restart the affected stateful
  components of `boot` (nil boot skips restarts). Returns a report
  {:reloaded :restarted :skipped :errors}."
  [boot files]
  (def report @{:reloaded @[] :restarted @[] :skipped @[] :errors @[]})
  (each file files
    (def [ok res] (protect (reload! file)))
    (cond
      (not ok)
      (array/push (report :errors) (string/format "%s: %s" file (describe res)))

      (= :skipped res)
      (array/push (report :skipped) file)

      (do (array/push (report :reloaded) file)
          (when boot
            (each k (affected-components boot file)
              (def [ok2 e2] (protect (system/restart (boot :system) k)))
              (if ok2
                (array/push (report :restarted) k)
                (array/push (report :errors)
                            (string/format "%q: %s" k (describe e2)))))))))
  report)

# -- the component -------------------------------------------------------

(defn- report-print [report]
  (each f (report :reloaded) (eprintf "void/dev reloaded %s" f))
  (each k (report :restarted) (eprintf "void/dev restarted %q" k))
  (each e (report :errors) (eprintf "void/dev reload error: %s" e)))

(defn tick!
  "One watcher pass: rescan, reload what changed against the current
  boot (plugin/current-boot). Returns the report, or nil when nothing
  changed."
  [inst]
  (def new (scan (inst :paths)))
  (def files (changed (inst :snapshot) new))
  (put inst :snapshot new)
  (unless (empty? files)
    (def report (apply-changes! plugin/current-boot files))
    (report-print report)
    report))

(defn start
  "Start the watch loop from the :watch slice of the :dev config
  ({:enabled :paths :interval}). Returns the instance table (or
  {:disabled true})."
  [cfg]
  (def opts (get cfg :watch {}))
  (if (= false (get opts :enabled))
    {:disabled true}
    (do
      (def paths (get opts :paths ["."]))
      (def interval (get opts :interval 0.5))
      (def inst @{:paths paths
                  :interval interval
                  :running true
                  :snapshot (scan paths)})
      (put inst :fiber
           (ev/go (fn watch-loop []
                    (while (inst :running)
                      (ev/sleep interval)
                      (when (inst :running)
                        (def [ok e] (protect (tick! inst)))
                        (unless ok
                          (eprintf "void/dev watcher: %s" (describe e))))))))
      inst)))

(defn stop
  "Ask the watch loop to exit (it wakes from its sleep within one
  :interval)."
  [inst]
  (when (get inst :running)
    (put inst :running false)))

(def component
  "The :dev/watcher system component."
  (system/component :dev/watcher
    :doc "Polling file watcher: env reload + auto-restart of stateful components."
    :config {:key :dev}
    :start (fn [_ cfg] (start (or cfg {})))
    :stop stop))
