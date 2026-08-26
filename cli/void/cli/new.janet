### void/cli/new — `void new NAME`: the project skeleton (ROADMAP 1.6).
###
### The template is data — a tuple of {:path :render} entries, each
### :render a pure (fn [name] string) — so a later `void make` can
### merge project-local overrides over it (SPEC §5.17: templates as
### data, overridable by the project). The generated project is the
### run!/CLI convention in miniature: main.janet defines `app` (boot
### options the CLI reads) and (main) as (void/run! app); app.janet is
### the application plugin contributing routes.

(defn- render-project [name]
  (string
    `(declare-project
  :name "` name `"
  :description "A void application."
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core / void-http / void-dev must be on the module path as well —
# until the packages are published, jpm install them from a void
# checkout (core/, http/, dev/).
`))

(defn- render-main [name]
  (string
    `### ` name ` — entrypoint. Run the app with `
    "`janet main.janet`"
    `; the
### void CLI (void routes, void repl, ...) reads the app binding below.
(import void)
(import void/http)
(import void/dev)
(import ./app)

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins [:void/http :void/dev :` name `/app]
   :profile (keyword (or (os/getenv "VOID_PROFILE") "dev"))})

(defn main [& args]
  (void/run! app))
`))

(defn- render-app [name]
  (string
    `### ` name `/app — the application plugin: routes and handlers.
### Handlers are registered as symbols (late binding): redefine one in
### the repl and the running route table picks it up immediately.
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)

(defn home
  "GET / — replace me."
  [req]
  (ring/response 200 "hello from ` name `\n"
                 @{"content-type" "text/plain; charset=utf-8"}))

(plugin/defcontribution :void.http/route-source
  {:name :` name `/routes
   :routes (router/routes {}
             (router/GET "/" 'home {:name :home}))
   :env (router/env-ref (curenv))})

(plugin/defplugin ` name `/app
  :doc "` name ` application plugin."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1"})
`))

(defn- render-config [name]
  (string
    `# ` name ` :dev profile config layer (void/core/config: plugin
# defaults <- config files <- VOID_* env vars <- CLI overrides).
{:http {:port 8080}}
`))

(defn- render-gitignore [name]
  ".void/\njpm_tree/\n")

(defn- render-readme [name]
  (string
    "# " name `

A [void](https://github.com/bondiano/void) application.

    janet main.janet    # run the app (dev profile: netrepl + watcher)
    void routes         # print the route table
    void repl           # repl into the running process
`))

(def template
  "The project skeleton as data: {:path :render} entries."
  [{:path "project.janet" :render render-project}
   {:path "main.janet" :render render-main}
   {:path "app.janet" :render render-app}
   {:path "config/dev.janet" :render render-config}
   {:path ".gitignore" :render render-gitignore}
   {:path "README.md" :render render-readme}])

(defn- valid-name? [name]
  (peg/match '(* (range "az") (any (+ (range "az") (range "09") "-")) -1)
             name))

(defn- ensure-dirs [path]
  (def parts (string/split "/" path))
  (var cur "")
  (each part (drop -1 parts)
    (set cur (if (empty? cur) part (string cur "/" part)))
    (unless (os/stat cur)
      (os/mkdir cur))))

(defn create
  ``Create a project skeleton: `void new NAME` writes the template into
  ./NAME (which must not exist yet). Returns the tuple of files
  written.``
  [&opt name]
  (when (nil? name)
    (error "usage: void new NAME"))
  (unless (valid-name? name)
    (errorf "project name %q must match [a-z][a-z0-9-]* (it becomes the plugin name %s/app)"
            name name))
  (when (os/stat name)
    (errorf "%q already exists" name))
  (os/mkdir name)
  (def written
    (seq [{:path path :render render} :in template]
      (def full (string name "/" path))
      (ensure-dirs full)
      (spit full (render name))
      full))
  (each f written (print "  created " f))
  (printf "\n  cd %s && janet main.janet" name)
  (tuple ;written))
