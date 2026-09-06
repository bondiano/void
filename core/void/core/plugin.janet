### void/core/plugin — plugin API.
###
### Plugin = a janet package exporting a manifest: a frozen struct with
### :void-api, :version, :requires (semver), :config-key/-schema,
### :when, :components, :contributes, :extension-points and :on-load.
### Extension point = a named contract: contribution schema +
### :cardinality (:many/:single/:single-required) + a :reduce fold +
### optional cross-checks. Bootstrap runs seven phases, all before
### anything opens a port: load -> config -> conditional -> extension
### resolution -> graph -> start -> ready; every phase collects its
### errors and fails in one batch naming the source plugin. `dry-run`
### executes phases 1-5 only — full validation of a system
### configuration in CI in milliseconds. REPL tools: (plugin/inspect),
### (plugin/why :key), (plugin/extension :point).
###
### This module is the facade: the API every package imports as
### `plugin/…`, re-exported from the four modules that own it —
### void/core/semver (versions and constraints), void/core/extension
### (point contracts, the collector, resolution), void/core/manifest
### (what a plugin declares, the registry, `defplugin`) and
### void/core/boot (the phases, the lifecycle, `current-boot`, the
### REPL tools). Each binding below is the owner's own — docstring,
### macro flag and, for `current-boot`, the var cell — so `(doc
### plugin/x)` and a read of `plugin/current-boot` see exactly what
### the owner has. The owner modules are importable on their own; the
### facade exports only what it always did.

(defn- re-export
  "Bind `names` from the module at `path` in this module's env, sharing
  each owner binding through a prototype: the value, the docstring,
  the macro flag and a var's cell all stay the owner's. A name the
  owner does not export is a load-time error — a facade that silently
  exported nil would fail at the first caller instead."
  [path names]
  (def env (require path))
  (each name names
    (def binding (in env name))
    (unless binding
      (errorf "void/core/plugin: %s exports no %q" path name))
    (put (curenv) name (table/setproto @{} binding))))

(re-export "./semver"
           ['parse-version 'satisfies?])

(re-export "./extension"
           ['extension-point 'contribute! 'declare-point! 'defextension-point
            'core-points])

(re-export "./manifest"
           ['manifest 'manifest-registry 'register-manifest! 'defplugin])

(re-export "./boot"
           ['current-boot 'bootstrap 'start! 'shutdown! 'dry-run
            'extension 'health 'inspect 'why])
