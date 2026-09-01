### void/cli/new — `void new NAME`: the project skeleton.
###
### The template is data — a tuple of {:path :render} entries, each
### :render a pure (fn [name] string) over the one hole this generator
### has (SPEC §5.17: templates as data, overridable by the project;
### ./make is where a project overrides one). The generated project is
### the run!/CLI convention in miniature: main.janet defines `app` (the
### boot options the CLI reads) and a `main` that runs it, and app.janet
### is the application plugin contributing routes.
###
### The generated files also have to be *deployable*, and that is one
### line each in two of them: `declare-executable` in project.janet, so
### that `jpm build` produces the single binary of SPEC §9, and a `main`
### that reads the profile at run time rather than in a value — because
### `jpm build` marshals this project's values into the executable, and
### a profile computed in `app` would be the profile of the machine
### that built it (docs/DEPLOY.md).

(import ./template)

(def project-template
  "project.janet: one dependency, and the executable target."
  ```
(declare-project
  :name "{{name}}"
  :description "A void application."
  # One dependency: void installs as a single bundle (ADR-0020), and
  # everything it needs — spork, and the framework's own packages —
  # comes with it. "jpm --local deps" pins this version in ./jpm_tree,
  # which the void binary uses in preference to the tree it was
  # installed into.
  :dependencies ["https://github.com/bondiano/void.git"])

# "jpm --local build" writes build/{{name}} — one file, no janet on the
# target and nothing to install (docs/DEPLOY.md). jpm marshals the
# "main" of the entry below into the executable and links the native
# modules it finds statically, which is why main.janet reads the
# profile at run time rather than into a value.
(declare-executable
  :name "{{name}}"
  :entry "main.janet"
  :install false)
```)

(def main-template
  "main.janet: the boot options, and the two ways to start them."
  ```
### {{name}} — entrypoint. Run the app with `void dev` (or
### `janet main.janet`); the void CLI (void routes, void repl, ...)
### reads the app binding below.
(import void/cli :as cli)
(import void/http)
(import void/html)
(import void/htmx)
(import void/dev)
(import ./app)

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins [:void/http :void/html :void/htmx :void/dev :{{name}}/app]})

# void/dev is a dev-time plugin: it serves a repl and watches the tree,
# and it builds that repl's environment with `require` — which a single
# binary has no source tree to require from (docs/DEPLOY.md). So the
# production composition is this one without it, and dropping a plugin
# from a list is the whole of the change.
(defn plugins
  "The composition for a profile."
  [profile]
  (if (= :prod profile)
    (filter |(not= :void/dev $) (app :plugins))
    (app :plugins)))

(defn main [& args]
  # The profile is read here rather than in `app` above: `jpm build`
  # marshals this file's values into the executable, so anything a
  # value computes is computed once, on the machine that built it.
  (def profile (keyword (or (os/getenv "VOID_PROFILE") "dev")))
  # cli/app-main runs the app when there are no arguments and is the
  # `void` binary when there are — so `./build/{{name}} db migrate`
  # works on a target with no janet and no source tree, against exactly
  # the composition inside this executable (docs/DEPLOY.md).
  (cli/app-main {:plugins (plugins profile) :profile profile} ;(drop 1 args)))
```)

(def app-template
  "app.janet: the application plugin — schema, views, routes."
  ```
### {{name}}/app — the application plugin: schema, views, routes.
### Handlers are registered as symbols (late binding): redefine one in
### the repl — or save this file with the watcher running — and the
### running app picks it up; route and metadata edits rebuild the
### table on the fly.
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx/hx :as hx)

# -- schema: one source of truth for validation and form markup ----------

(def Entry
  "A guestbook entry — drives both form/check and form/form."
  {:name [:string {:min 1 :max 40}]
   :message [:string {:min 1 :max 400}]})

# -- state (in-memory until void/db lands in your :plugins) --------------

(def entries @[])

# -- views (plain functions returning hiccup) ----------------------------

(defn layout [content context]
  (html/html5
    [:head
     [:meta {:charset "utf-8"}]
     [:title "{{name}}"]
     [:script {:src "https://unpkg.com/htmx.org@2.0.7"}]]
    [:body [:main content]]))

(defn guestbook-view
  "The #guestbook fragment: schema-driven form plus the entries list.
  On an invalid submission the caller passes the raw values and the
  schema errors back in and the same markup re-renders annotated."
  [&opt values errors]
  [:div {:id "guestbook"}
   [:h1 "{{name}} guestbook"]
   (form/form Entry
     {:action "/entries"
      :values values
      :errors errors
      :fields {:message {:control :textarea}}
      :submit "Sign"
      :attrs (hx/post "/entries" :target "#guestbook" :swap :outer-html)})
   [:ul {:class "entries"}
    (if (empty? entries)
      [:li {:class "empty"} "No entries yet — sign the book."]
      (seq [e :in (reverse entries)]
        [:li [:strong (e :name)] ": " (e :message)]))]])

# -- handlers ------------------------------------------------------------

(defn home
  "GET / — the full page."
  [req]
  (html/page (guestbook-view) {:layout layout}))

(defn create-entry
  "POST /entries — form/check validates and coerces against Entry;
  invalid input re-renders the fragment with per-field errors."
  [req]
  (def result (form/check Entry (req :form)))
  (if (empty? (result :errors))
    (do
      (array/push entries (result :value))
      (html/page (guestbook-view) {:layout layout}))
    (html/page (guestbook-view (req :form) (result :errors))
               {:layout layout})))

# -- routes --------------------------------------------------------------

# defroutes writes the :void.http/route-source contribution: handler
# symbols are quoted for you (late binding) and name their route.
(router/defroutes :{{name}}/routes
  (GET "/" home)
  # :void.htmx/partial — an HX-Request gets the bare fragment; a plain
  # form POST still gets the full page
  (POST "/entries" create-entry
        {:name :entries/create :void.htmx/partial true}))

(plugin/defplugin {{name}}/app
  :doc "{{name}} application plugin."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"})
```)

(def config-template
  "config/dev.janet: the file layer of the config chain."
  ```
# {{name}} :dev profile config layer (void/core/config: plugin
# defaults <- config files <- VOID_* env vars <- CLI overrides).
{:http {:port 8080}}
```)

(def gitignore-template
  "What never belongs in the repository."
  ```
.void/
jpm_tree/
build/
```)

(def readme-template
  "README.md: the four things to run, in the order they are run."
  ```
# {{name}}

A [void](https://github.com/bondiano/void) application — a
server-rendered HTMX guestbook with schema-validated forms.

    jpm --local deps    # pin void in ./jpm_tree (once, and after a bump)
    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void repl           # repl into the running process

Scaffold a CRUD resource — entity, form, views, routes, migration and
a suite, every one of them a projection of one declaration:

    void make resource Product name:string price:int notes:text?

Scaffold the pages every application writes by hand — register, sign
in, sign out, a password reset and an address to verify — on top of
void/auth, with a suite that drives all of them:

    void make auth

Lock the composition, so that "why is the middleware stack different in
production" is a diff rather than an investigation:

    void plugins lock   # writes void.lock — commit it
    void plugins check  # in CI

Ship it as one file, with no janet and no source tree on the target
(docs/DEPLOY.md in the void repository):

    jpm --local build
    VOID_PROFILE=prod VOID_HTTP__PORT=8080 ./build/{{name}}

Edit app.janet while `void dev` runs: handler changes are live (late
binding), and new routes or metadata edits rebuild the route table
automatically.
```)

(defn- one [tmpl]
  (fn [name] (template/render tmpl {:name name})))

(def- render-project (one project-template))
(def- render-main (one main-template))
(def- render-app (one app-template))
(def- render-config (one config-template))
(def- render-readme (one readme-template))
(def- render-gitignore (one gitignore-template))

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
  (printf "\n  cd %s && void dev" name)
  (tuple ;written))
