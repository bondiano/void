### void/html — server-side rendering plugin.
###
### The view layer over void/http: handlers return lazy view responses
### (html/page, html/fragment) carrying content + layout as data, and
### the :void.html/render middleware, after :void.http/responding, renders them
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
(import ./hiccup :as hiccup)
(import ./form :as form)
(import ./assets :as assets)
(import ./tailwind :as tailwind)
(import ./temple :as temple)
(import void/core/util :as util)

# -- re-exported view vocabulary -----------------------------------------

(def raw "See hiccup/raw." hiccup/raw)
(def raw? "See hiccup/raw?." hiccup/raw?)
(def escape "See hiccup/escape." hiccup/escape)
(def json-script "See hiccup/json-script." hiccup/json-script)
(def render "See hiccup/render." hiccup/render)
(def render-string "See hiccup/render-string." hiccup/render-string)
(def html5 "See hiccup/html5." hiccup/html5)
(def classes "See hiccup/classes." hiccup/classes)

# -- boot context --------------------------------------------------------

# What the :before-start hook builds and `context` answers.
(def HtmlContext :typedef
  '{:engine-name :keyword :engines {:keyword :any}
    :assets {:prefix :string :manifest (or {:string :string} :nil)}
    :config {:any :any} & r})

(var current-context {:type HtmlContext?}
  "The running html context (set by the :before-start hook):
  :engine-name, :engines (name -> engine contribution), :assets
  ({:prefix :manifest}), :config. One per process — a hook builds it,
  not a component, so it is a var rather than a `system/ambient`."
  nil)

(defn- context
  {:params [] :ret HtmlContext :throws [:string]}
  "The running html context, or an error naming the hook that builds
  it — read by every function below that needs the selected engine or
  the asset manifest."
  []
  (or current-context
      (error "void/html is not booted — plugin/start! builds the html context at :before-start")))

# -- extension point -----------------------------------------------------

(plugin/defextension-point :void.html/engine
  :doc "View engines: {:name :render (fn [view context] bytes)}; config [:html :engine] selects the default, a view response's :void.html/engine key overrides per response. The context carries :request, :layout and the response's :void.html/context entries."
  :schema {:name :keyword
           :render :function
           :doc [:optional :string]}
  :key :name :what "view engine" :index true)

(plugin/contribute! :void.html/engine
  {:name :hiccup
   :doc "The hiccup pipeline: a view is hiccup data or (fn [context] hiccup); a layout is (fn [content context] hiccup)"
   :render (fn hiccup-render [view context]
             (def content (if (util/callable? view) (view context) view))
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
  {:params [:any
            (or {:layout :any :status :number? :headers (or {:any :any} :nil)
                 :context (or {:any :any} :nil) :engine :keyword?
                 :title :any :head :any :partial :any & r}
                :nil)]
   :ret HtmlView
   :throws [:string]}
  ``A lazy view response — content and layout as data, rendered by the
  :void.html/render middleware on the way out:

      (html/page [:h1 "orders"] {:layout layouts/base})

  opts: :layout (engine-specific layout value, nil for none), :status
  (200), :headers (merged over text/html), :context (extra engine
  context), :engine (override config [:html :engine] for this
  response), :title and :head (the page's head slots — the context
  keys :void.html/title and :void.html/head a layout reads), and
  :partial — the subtree an htmx swap into an element gets instead of
  the page (hiccup, or a thunk returning it), rendered with no layout:

      (html/page (list-page rows) {:layout base :partial (rows-fragment rows)})

  htmx 4 says which one it wants in HX-Request-Type ("partial" for a
  swap into an element, "full" for the body, a boosted link, a
  history restore), so one handler answers both without a route
  flag; a response without :partial ignores the header.``
  [content &opt opts]
  (default opts {})
  (when (nil? content)
    (error "html/page needs non-nil content"))
  (def resp @{:status (get opts :status 200)
              :headers (merge @{"content-type" "text/html; charset=utf-8"}
                              (get opts :headers {}))
              :void.html/content content
              :void.html/layout (get opts :layout)
              :void.html/context (merge (or (get opts :context) {})
                                        (if-let [t (get opts :title)] {:void.html/title t} {})
                                        (if-let [h (get opts :head)] {:void.html/head h} {}))})
  (when-let [e (get opts :engine)]
    (put resp :void.html/engine e))
  (when-let [p (get opts :partial)]
    (put resp :void.html/partial p))
  resp)

(defn fragment
  {:params [:any
            (or {:status :number? :headers (or {:any :any} :nil)
                 :context (or {:any :any} :nil) :engine :keyword?
                 :title :any :head :any :partial :any & r}
                :nil)]
   :ret HtmlView
   :throws [:string]}
  "A lazy view response with no layout — html/page with :layout nil
  forced (partials, htmx fragments)."
  [content &opt opts]
  (page content (merge (or opts {}) {:layout nil})))

(defn view-response?
  {:params [:any] :ret :boolean :narrows {:void.html/content :any & r}}
  "Is this response a lazy view response the render middleware will
  finalize?"
  [resp]
  (and (dictionary? resp)
       (not (nil? (get resp :void.html/content)))))

(defn partial-request?
  {:params [(or {:headers (or {:string :string} :nil) & r} :nil)] :ret :boolean :narrows :any}
  ``Is this request for a fragment — htmx 4's HX-Request-Type:
  partial, a swap that lands in some element? One header read, here
  rather than in void/htmx, because the render middleware is what
  chooses between a page's content and its :partial.``
  [req]
  (= "partial" (get-in req [:headers "hx-request-type"])))

(defn- finalize
  {:params [@{:void.html/content :any :void.html/layout :any
              :void.html/context (or {:any :any} :nil)
              :void.html/engine :keyword? :void.html/partial :any & r}
            (or {:headers (or {:string :string} :nil) & r} :nil)]
   :ret @{:void.html/content :any :void.html/layout :any
          :void.html/context (or {:any :any} :nil) :body :any & r}
   :throws [:string]}
  "Render a view response's content (or its :partial, for a partial
  request) through the selected engine, and put the result on
  :body."
  [resp req]
  (def ctx (context))
  (def ename (get resp :void.html/engine (ctx :engine-name)))
  (def engine
    (or (get-in ctx [:engines ename])
        (errorf "unknown view engine %q (contributed: %s)"
                ename
                (string/join (map |(string/format "%q" $)
                                  (sorted (keys (ctx :engines))))
                             " "))))
  # a partial answers a partial request in place of the page, with no
  # layout — a thunk is called here so the page's tree is not built
  # for a request that wanted a row
  (def partial (get resp :void.html/partial))
  (def [content layout]
    (if (and partial (partial-request? req))
      [(if (util/callable? partial) (partial) partial) nil]
      [(resp :void.html/content) (get resp :void.html/layout)]))
  (def render-context
    (merge (or (get resp :void.html/context) {})
           {:request req}
           (if layout {:layout layout} {})))
  (put resp :body ((engine :render) content render-context))
  resp)

(defn render-now
  {:params [:any (or {:headers (or {:string :string} :nil) & r} :nil)]
   :ret :any
   :throws [:string]}
  ``Render a lazy view response here and now instead of leaving it to
  the render middleware on the way out: the same response, with `:body`
  the rendered page. Anything that is not a view response passes
  through untouched, so a caller that may be handed a redirect does not
  branch.

  What a caller needs when it *holds* the page rather than returns it.
  `void/datastar`'s `morph-stream` re-renders on every poke and never
  passes through a middleware chain, so without this the live half of
  a page and its ordinary response are two render paths — which is
  exactly what void/dash hit (ADR-0043 §5): a handler answering
  `html/page` and a stream calling the layout by hand, one of which
  will drift.

  `req` is the request the page is for; it reaches the layout as
  `:request` in the render context, and its absence is only the
  absence of that.``
  [resp &opt req]
  (if (view-response? resp)
    (finalize resp (or req {}))
    resp))

(plugin/contribute! :void.http/middleware
  {:name :void.html/render
   :after :void.http/responding
   :before :void.http.stage/pre-serialization
   :doc "Render lazy view responses (:void.html/content) through the selected engine"
   :wrap (fn [handler]
           (fn render-view [req]
             (def resp (handler req))
             (if (view-response? resp)
               (finalize resp req)
               resp)))})

# -- flash ---------------------------------------------------------------
#
# A message that survives one redirect: put in the session by the
# handler that did the work, taken out by the page that renders next.
# The session is void/http's ((req :session), a table the middleware
# saves after the handler), so there is no middleware here — the key
# is data in the session like any other, and the page that reads it
# removes it.

(def flash-key
  "Where flashes wait in the session."
  :void.html/flash)

(defn- session-of
  {:params [(or {:session (or @{:any :any} :nil) & r} :nil)]
   :ret @{:any :any}
   :throws [:string]}
  "The request's session table, or an error naming the config that
  puts one there."
  [req]
  (or (get req :session)
      (error "html/flash! needs a session — enable [:http :session] (void/http's session middleware puts one on the request)")))

(defn flash!
  {:params [(or {:session (or @{:any :any} :nil) & r} :nil)
            (enum :ok :warn :danger :note) :any]
   :ret :nil
   :throws [:string]}
  ``Queue a message for the next page: `tone` is :ok, :warn, :danger
  or :note, `text` the sentence.

      (html/flash! req :ok "Saved.")
      (ring/redirect "/orders")``
  [req tone text]
  (def s (session-of req))
  (put s flash-key [;(get s flash-key []) {:tone tone :text (string text)}])
  nil)

(defn flashes
  {:params [(or {:session (or @{:any :any} :nil) & r} :nil)]
   :ret [{:tone :keyword :text :string}]}
  ``The waiting messages — `[{:tone :text} ...]` — taken out of the
  session, so they show once. An empty tuple without a session.``
  [req]
  (if-let [s (get req :session)]
    (let [out (get s flash-key [])]
      (put s flash-key nil)
      out)
    []))

(defn flash-view
  {:params [(or {:session (or @{:any :any} :nil) & r} :nil)] :ret (or :tuple :nil)}
  ``The waiting messages as hiccup, one `.vd-flash.is-<tone>` block
  each — for a layout's slot above the content. nil when there are
  none.``
  [req]
  (def all (flashes req))
  (unless (empty? all)
    [:div {:class "vd-flashes"}
     (seq [f :in all]
       [:p {:class (string "vd-flash is-" (f :tone))} (f :text)])]))

# -- pager ---------------------------------------------------------------

(defn pager
  {:params [{:page :number? :per-page :number? :total :number?
             :href (or (fn [a] :string) :nil)
             :attrs (or (fn [a] :any) :nil)
             :noun :string? & r}]
   :ret :tuple
   :throws [:string]}
  ``Pagination as hiccup — the count, previous, "page N of M", next:

      (html/pager {:page 2 :per-page 25 :total 130
                   :href (fn [p] (string "/orders?page=" p))})

  :href builds a page's URL; :attrs, when given, is `(fn [url] attrs)`
  and its result is merged onto each link (an hx/get* for a swap).
  :noun is the counted thing ("row" by default; the plural adds an
  s). Numbers stay numbers: a page count under one is one page.``
  [opts]
  (def page* (max 1 (get opts :page 1)))
  (def per (max 1 (get opts :per-page 25)))
  (def total (get opts :total 0))
  (def pages (max 1 (math/ceil (/ total per))))
  (def href (or (opts :href) (error "html/pager needs :href")))
  (def extra (get opts :attrs (fn [_] {})))
  (def noun (get opts :noun "row"))
  (defn link
    {:params [:number :string] :ret :tuple}
    "One pager link — previous, or next — with :attrs merged on."
    [p text]
    (def url (href p))
    [:a (merge {:href url} (extra url)) text])
  [:div {:class "vd-pager"}
   [:span {:class "vd-count"} (string total " " noun (if (= 1 total) "" "s"))]
   (when (> page* 1) (link (dec page*) "← previous"))
   [:span (string "page " page* " of " pages)]
   (when (< page* pages) (link (inc page*) "next →"))])

# -- assets --------------------------------------------------------------

(defn- normalize-prefix
  {:params [:string] :ret :string}
  "A mount prefix with a leading and a trailing slash, whichever it
  was missing."
  [p]
  (def lead (if (string/has-prefix? "/" p) p (string "/" p)))
  (if (string/has-suffix? "/" lead) lead (string lead "/")))

(defn- build-assets-state
  {:params [(or {:tailwind (or {:any :any} :nil) :prefix :string?
                :manifest :string? :out :string?
                :mode (or (enum :auto :passthrough :manifest) :nil) & r}
               :nil)]
   :ret {:prefix :string :manifest (or {:string :string} :nil)}
   :throws [:string]}
  "The :assets slice of the html context: the normalized prefix, and
  the fingerprint manifest loaded per [:html :assets :mode] — nil for
  dev passthrough."
  [acfg]
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
  {:params [:string] :ret :string :throws [:string]}
  ``URL for a logical asset path through the loaded manifest, or the
  passthrough URL when none is loaded (see assets/href):

      (html/asset "css/app.css")  # "/assets/css/app-2f4e881c.css"``
  [logical]
  (def a ((context) :assets))
  (assets/href (a :manifest) (a :prefix) logical))

# -- context build (:before-start hook) ----------------------------------

(defn build-context
  {:params [:any]
   :ret @{:engine-name :keyword :engines {:keyword :any}
          :assets {:prefix :string :manifest (or {:string :string} :nil)}
          :config {:any :any} & r}
   :throws [:string]}
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
            (util/names-str (keys engines))))
  (set current-context
       @{:config cfg
         :engine-name ename
         :engines engines
         :assets (build-assets-state (cfg :assets))}))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :before :void.core/configured
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
  {:params [] :ret {:root :string? :out :string? :prefix :string? :manifest :string?
                    :tailwind (or {:any :any} :nil) & r}
   :throws [:string]}
  "The [:html :assets] slice of the running composition."
  []
  (get-in (context) [:config :assets] {}))

(defn build-assets!
  {:params [(or {:root :string? :out :string? :manifest :string?
                :tailwind (or {:any :any} :nil) & r}
               :nil)]
   :ret @{:string :string}
   :throws [:string]}
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
   :doc "Compile and fingerprint the assets"
   :args []
   :fn (fn cli-build []
         (def cfg (asset-config))
         (def manifest (build-assets!))
         (printf "assets     %s -> %s (%d files)"
                 (cfg :root) (cfg :out) (length manifest))
         (each [logical target] (sorted-by first (pairs manifest))
           (printf "  %s -> %s" logical target))
         manifest)})

(defn- start-network!
  {:params [] :ret :nil}
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
  (def sys (get (plugin/running-boot) :system))
  (when sys
    (each k (get-in sys [:providers :void/tls] [])
      (unless (= :running (get-in sys [:states k]))
        (system/start sys [k])))))

(plugin/contribute! :void.core/cli
  {:name :assets/install
   :read-only? false
   :doc "Download the standalone tailwind compiler"
   :args []
   :fn (fn cli-install []
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
   :doc "Where the assets and the tailwind compiler are"
   :args []
   :fn (fn cli-info []
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
