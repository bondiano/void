### void/html — server-side rendering plugin (SPEC.md §5.4, ROADMAP
### 1.2).
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
### middleware).

(import void/core/plugin :as plugin)
(import void/http/middleware :as middleware)
(import ./hiccup :as hiccup)
(import ./form :as form)
(import ./assets :as assets)
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

(plugin/defcontribution :void.html/engine
  {:name :hiccup
   :doc "The hiccup pipeline: a view is hiccup data or (fn [context] hiccup); a layout is (fn [content context] hiccup)"
   :render (fn hiccup-render [view context]
             (def content (if (callable? view) (view context) view))
             (hiccup/render
               (if-let [layout (get context :layout)]
                 (layout content context)
                 content)))})

(plugin/defcontribution :void.html/engine
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

(plugin/defcontribution :void.http/middleware
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

(plugin/defcontribution :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :html/build-context
   :doc "Resolve the view engine and asset manifest before the route table builds"
   :fn (fn build! [boot] (build-context boot))})

# -- manifest ------------------------------------------------------------

(def Config
  "Schema of the :html config slice."
  {:engine [:optional :keyword]
   :assets [:optional {:mode [:optional [:enum :auto :passthrough :manifest]]
                       :root [:optional :string]
                       :out [:optional :string]
                       :prefix [:optional :string]
                       :manifest [:optional :string]}]})

(plugin/defplugin void/html
  :doc "SSR view layer: hiccup pipeline with function components, layouts and partials; form helpers projected from schemas; fingerprinted asset manifest with dev passthrough; temple as the alternative engine behind :void.html/engine."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :html
  :config-schema Config
  :config-defaults {:engine :hiccup})
