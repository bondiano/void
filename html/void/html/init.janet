### void/html — server-side rendering plugin.
###
### The view layer over void/http: handlers return lazy view responses
### (html/page, html/fragment) carrying content + layout as data, and
### the :void.html/render middleware at the response phase renders them
### through the engine selected by config [:html :engine]. Keeping the
### response unrendered until the chain unwinds is what lets middleware
### deeper in the chain — void/htmx's partial stripping — swap the
### layout out before any bytes exist. Engines are an extension point
### (:void.html/engine): the hiccup pipeline is the default, temple the
### built-in alternative, both contributed here through the same point
### third-party engines would use. Asset URLs resolve through the
### fingerprint manifest when one is loaded (prod) and pass through
### unchanged when none is (dev, served by void/http's static
### middleware). A stylesheet that has to be compiled first is one
### `:steps` thunk in front of that walk (./tailwind) and nothing else:
### `void assets build` compiles into the asset root and fingerprints
### what it finds there, so `html/asset` cannot tell a generated file
### from a hand-written one, and no node ever enters the picture.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/http/middleware :as middleware)
(import ./hiccup :as hiccup)
(import ./form :as form)
(import ./assets :as assets)
(import ./tailwind :as tailwind)
(import ./temple :as temple)

# -- re-exported view vocabulary -----------------------------------------

(def raw "See hiccup/raw." hiccup/raw)
(def escape "See hiccup/escape." hiccup/escape)
(def render "See hiccup/render." hiccup/render)
(def render-string "See hiccup/render-string." hiccup/render-string)
(def html5 "See hiccup/html5." hiccup/html5)
(def classes "See hiccup/classes." hiccup/classes)

# -- boot context --------------------------------------------------------

(var current-context
  "The running html context (set by the :before-start hook):
  :engine-name, :engines (name -> engine contribution), :assets
  ({:prefix :manifest}), :config. One per process, like
  plugin/current-boot."
  nil)

(defn- context []
  (or current-context
      (error "void/html is not booted — plugin/start! builds the html context at :before-start")))

# -- extension point -----------------------------------------------------

(plugin/defextension-point :void.html/engine
  :doc "View engines: {:name :render (fn [view context] bytes)}; config [:html :engine] selects the default, a view response's :void.html/engine key overrides per response. The context carries :request, :layout and the response's :void.html/context entries."
  :schema {:name :keyword
           :render :function
           :doc [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate view engine %q" (c :name)))
                (put seen (c :name) true)))
  :reduce (fn [contribs] (tabseq [c :in contribs] (c :name) c)))

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(plugin/contribute! :void.html/engine
  {:name :hiccup
   :doc "The hiccup pipeline: a view is hiccup data or (fn [context] hiccup); a layout is (fn [content context] hiccup)"
   :render (fn hiccup-render [view context]
             (def content (if (callable? view) (view context) view))
             (hiccup/render
               (if-let [layout (get context :layout)]
                 (layout content context)
                 content)))})

(plugin/contribute! :void.html/engine
  {:name :temple
   :doc "spork/temple templates: a view is a compiled template function, a layout template receives the rendered view as (args :content)"
   :render temple/engine-render})

# -- view responses ------------------------------------------------------

(defn page
  ``A lazy view response — content and layout as data, rendered by the
  :void.html/render middleware on the way out:

      (html/page [:h1 "orders"] {:layout layouts/base})

  opts: :layout (engine-specific layout value, nil for none), :status
  (200), :headers (merged over text/html), :context (extra engine
  context), :engine (override config [:html :engine] for this
  response).``
  [content &opt opts]
  (default opts {})
  (when (nil? content)
    (error "html/page needs non-nil content"))
  (def resp @{:status (get opts :status 200)
              :headers (merge @{"content-type" "text/html; charset=utf-8"}
                              (get opts :headers {}))
              :void.html/content content
              :void.html/layout (get opts :layout)
              :void.html/context (get opts :context)})
  (when-let [e (get opts :engine)]
    (put resp :void.html/engine e))
  resp)

(defn fragment
  "A lazy view response with no layout — html/page with :layout nil
  forced (partials, htmx fragments)."
  [content &opt opts]
  (page content (merge (or opts {}) {:layout nil})))

(defn view-response?
  "Is this response a lazy view response the render middleware will
  finalize?"
  [resp]
  (and (dictionary? resp)
       (not (nil? (get resp :void.html/content)))))

(defn- finalize [resp req]
  (def ctx (context))
  (def ename (get resp :void.html/engine (ctx :engine-name)))
  (def engine
    (or (get-in ctx [:engines ename])
        (errorf "unknown view engine %q (contributed: %s)"
                ename
                (string/join (map |(string/format "%q" $)
                                  (sorted (keys (ctx :engines))))
                             " "))))
  (def render-context
    (merge (or (get resp :void.html/context) {})
           {:request req}
           (if-let [l (get resp :void.html/layout)] {:layout l} {})))
  (put resp :body ((engine :render) (resp :void.html/content) render-context))
  resp)

(plugin/contribute! :void.http/middleware
  {:name :void.html/render
   :phase middleware/phase/response
   :doc "Render lazy view responses (:void.html/content) through the selected engine"
   :wrap (fn [handler]
           (fn render-view [req]
             (def resp (handler req))
             (if (view-response? resp)
               (finalize resp req)
               resp)))})

# -- assets --------------------------------------------------------------

(defn- normalize-prefix [p]
  (def lead (if (string/has-prefix? "/" p) p (string "/" p)))
  (if (string/has-suffix? "/" lead) lead (string lead "/")))

(defn- build-assets-state [acfg]
  (def cfg (or acfg {}))
  # a half-named compile is refused here rather than at the first
  # build: the boot is where a developer is still reading errors
  (tailwind/configured? (get cfg :tailwind))
  (def prefix (normalize-prefix (get cfg :prefix "/assets/")))
  (def man-path (or (get cfg :manifest)
                    (when-let [out (get cfg :out)]
                      (string out "/manifest.jdn"))))
  (def manifest
    (case (get cfg :mode :auto)
      :passthrough nil
      :manifest (assets/load-manifest
                  (or man-path
                      (error "[:html :assets] :mode :manifest needs a :manifest or :out path")))
      :auto (when (and man-path (os/stat man-path))
              (assets/load-manifest man-path))))
  {:prefix prefix :manifest manifest})

(defn asset
  ``URL for a logical asset path through the loaded manifest, or the
  passthrough URL when none is loaded (see assets/href):

      (html/asset "css/app.css")  # "/assets/css/app-2f4e881c.css"``
  [logical]
  (def a ((context) :assets))
  (assets/href (a :manifest) (a :prefix) logical))

# -- context build (:before-start hook) ----------------------------------

(defn build-context
  "Assemble the html context from a boot value: resolve the engine
  point, check the configured engine exists, load the asset manifest
  per [:html :assets]. Normally called by the :before-start hook."
  [boot]
  (def cfg (or (get-in boot [:config :values :html]) {}))
  (def engines (or (get-in boot [:extensions :void.html/engine :resolved]) @{}))
  (def ename (get cfg :engine :hiccup))
  (unless (get engines ename)
    (errorf "config [:html :engine] selects unknown engine %q (contributed: %s)"
            ename
            (string/join (map |(string/format "%q" $) (sorted (keys engines))) " ")))
  (set current-context
       @{:config cfg
         :engine-name ename
         :engines engines
         :assets (build-assets-state (cfg :assets))}))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :html/build-context
   :doc "Resolve the view engine and asset manifest before the route table builds"
   :fn (fn build! [boot] (build-context boot))})

# -- the asset build -----------------------------------------------------
#
# Three commands, and between them the whole of "assets without node":
# `void assets install` puts the standalone tailwind compiler in this
# project's cache, `void assets build` compiles and fingerprints, and
# `void assets info` says where everything is — which is the command
# somebody runs when a build says it cannot find a compiler.
#
# `build` is the deploy step. It is a CLI command rather than a hook
# because a build is not a boot: it needs a bootstrapped composition to
# read `[:html :assets]` from, and nothing else — no port, no database,
# no component (`:needs` is empty).

(defn asset-config
  "The [:html :assets] slice of the running composition."
  []
  (get-in (context) [:config :assets] {}))

(defn build-assets!
  ``Build this composition's assets — the body of `void assets build`:
  compile the stylesheet when `[:html :assets :tailwind]` names one,
  then fingerprint everything under `:root` into `:out` and write the
  manifest. `overrides` replaces config keys for one call. Returns the
  manifest table.``
  [&opt overrides]
  (def cfg (merge (asset-config) (or overrides {})))
  (def root
    (or (cfg :root)
        (error "[:html :assets :root] is not set — the asset build needs the directory the served files live in")))
  (def out
    (or (cfg :out)
        (error "[:html :assets :out] is not set — the asset build needs somewhere to write the fingerprinted copies")))
  (def tw (get cfg :tailwind {}))
  (assets/build! {:root root
                  :out out
                  :manifest (cfg :manifest)
                  :steps (if-let [s (tailwind/step tw)] [s] [])}))

(plugin/contribute! :void.core/cli
  {:name :assets/build
   :read-only? false
   :doc "Compile and fingerprint the assets: void assets build"
   :fn (fn cli-build [& args]
         (unless (empty? args)
           (errorf "void assets build takes no arguments (got %q)" (string/join args " ")))
         (def cfg (asset-config))
         (def manifest (build-assets!))
         (printf "assets     %s -> %s (%d files)"
                 (cfg :root) (cfg :out) (length manifest))
         (each [logical target] (sorted-by first (pairs manifest))
           (printf "  %s -> %s" logical target))
         manifest)})

(defn- start-network!
  ``Start whatever provides `:void/tls` in this composition, if anything
  does.

  The download is the one thing in void/html that needs the network,
  and the network is somebody else's component: `:void/tls` publishes
  an *interface* and a composition either has an implementation of it or
  does not. A command's `:needs` are component keys, resolved before the
  command runs and fatal when unknown, so they cannot say "this one, if it
  is here" — hence this, which asks the running boot the same question
  `:needs` would have asked and leaves the answer to `run-command`'s stop.
  A composition without TLS starts nothing and gets `install!`'s refusal,
  which names both ways out.``
  []
  (def sys (get plugin/current-boot :system))
  (when sys
    (each k (get-in sys [:providers :void/tls] [])
      (unless (= :running (get-in sys [:states k]))
        (system/start sys [k])))))

(plugin/contribute! :void.core/cli
  {:name :assets/install
   :read-only? false
   :doc "Download the standalone tailwind compiler: void assets install"
   :fn (fn cli-install [& args]
         (unless (empty? args)
           (errorf "void assets install takes no arguments (got %q)" (string/join args " ")))
         (def cfg (get (asset-config) :tailwind {}))
         (start-network!)
         (def r (tailwind/install! cfg))
         (if (r :cached)
           (printf "tailwind %s is already at %s" (r :version) (r :path))
           (printf "tailwind %s -> %s (%d bytes, from %s)"
                   (r :version) (r :path) (r :bytes) (r :url)))
         (when (= "latest" (string (tailwind/setting cfg :version)))
           (printf "pin it with [:html :assets :tailwind :version] %q" (r :version)))
         r)})

(plugin/contribute! :void.core/cli
  {:name :assets/info
   :read-only? true
   :doc "Where the assets and the tailwind compiler are: void assets info"
   :fn (fn cli-info [& args]
         (unless (empty? args)
           (errorf "void assets info takes no arguments (got %q)" (string/join args " ")))
         (def a ((context) :assets))
         (def cfg (asset-config))
         (def tw (get cfg :tailwind {}))
         (printf "prefix     %s" (a :prefix))
         (printf "root       %s" (or (cfg :root) "— not set"))
         (printf "out        %s" (or (cfg :out) "— not set"))
         (printf "manifest   %s"
                 (if (a :manifest)
                   (string/format "%d entries" (length (a :manifest)))
                   "none — asset urls pass through (dev)"))
         (if-not (tailwind/configured? tw)
           (print "tailwind   not configured ([:html :assets :tailwind] :input/:output)")
           (do
             (printf "tailwind   %s -> %s" (tw :input) (tw :output))
             (printf "  platform %s" (or (tw :platform) (tailwind/platform)))
             (printf "  version  %s" (tailwind/setting tw :version))
             (def [ok found] (protect (tailwind/locate tw)))
             (cond
               (not ok) (printf "  compiler %s" (describe found))
               found (printf "  compiler %s (%s)" (found :path) (found :source))
               (do
                 (print "  compiler none — run `void assets install`")
                 (each p (tailwind/places tw) (printf "    looked in %s" p)))))))})

# -- manifest ------------------------------------------------------------

(def Config
  "Schema of the :html config slice."
  {:engine [:optional :keyword]
   :assets [:optional {:mode [:optional [:enum :auto :passthrough :manifest]]
                       :root [:optional :string]
                       :out [:optional :string]
                       :prefix [:optional :string]
                       :manifest [:optional :string]
                       # the standalone tailwind compiler: :input is
                       # the source stylesheet (which names its own
                       # template sources), :output is where the
                       # compiled css lands — inside :root, so dev
                       # serves it and the build fingerprints it
                       :tailwind [:optional {:enabled [:optional :boolean]
                                             :input [:optional :string]
                                             :output [:optional :string]
                                             :minify [:optional :boolean]
                                             :watch [:optional :boolean]
                                             :args [:optional [:vector :string]]
                                             :bin [:optional :string]
                                             :dir [:optional :string]
                                             :version [:optional :string]
                                             :platform [:optional :string]
                                             :timeout [:optional [:number {:min 1}]]
                                             :max-bytes [:optional [:number {:min 1}]]}]}]})

(plugin/defplugin void/html
  :doc "SSR view layer: hiccup pipeline with function components, layouts and partials; form helpers projected from schemas; fingerprinted asset manifest with dev passthrough and the standalone tailwind compiler as a build step; temple as the alternative engine behind :void.html/engine."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :html
  :config-schema Config
  :config-defaults {:engine :hiccup
                    :assets {:tailwind {:version (tailwind/defaults :version)
                                        :dir (tailwind/defaults :dir)}}}
  # inert in every composition that does not name a stylesheet, and in
  # every :prod one — which is why it can be here rather than in a
  # dev-only plugin the production composition would have to remember
  # to drop
  :components [tailwind/component])
