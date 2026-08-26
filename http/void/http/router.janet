### void/http/router — routes as data, PEG dispatch, metadata merge
### (SPEC.md §5.1 + part II §2, ADR-0002, ADR-0005, ROADMAP 1.1).
###
### Routes are plain data: `route`/`GET`/`group`/`routes` are ordinary
### functions building tables, macros nowhere. `build-table` turns the
### route sources into an immutable route table — patterns compiled to
### PEGs, metadata merged (global -> group -> route) through
### void/core/meta with provenance kept for explain, handler symbols
### resolved to their module environments (late binding, ADR-0002: the
### env table is looked up per call, so a REPL redefinition is live
### without a rebuild), and the middleware chain composed per route —
### nothing is decided on the hot path. Every validation failure across
### every route is reported in one batch. The table itself is a frozen
### value; the running server holds it through a one-slot `cell`, and
### `swap!` replaces it atomically — there is no half-rebuilt routing.

(import void/core/meta :as meta)
(import ./middleware :as mw)
(import ./wire :as wire)

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

# -- route declarations (data-first, ADR-0004) ---------------------------

(def- methods
  {:get true :head true :post true :put true :patch true
   :delete true :options true :any true})

(defn route
  "Build one route declaration: method, pattern, handler (symbol for
  late binding — a function literal works but is :no-reload), metadata."
  [method pattern handler &opt rmeta]
  (unless (in methods method)
    (errorf "route method must be one of %s, got %q"
            (string/join (map string (sorted (keys methods))) " ") method))
  (unless (and (string? pattern) (string/has-prefix? "/" pattern))
    (errorf "route pattern %q must be a string starting with /" pattern))
  (unless (or (symbol? handler) (callable? handler))
    (errorf "route %q %q: handler must be a symbol or a function, got %q"
            method pattern handler))
  {:route true :method method :pattern pattern :handler handler
   :meta (or rmeta {})})

(defn GET [pattern handler &opt rmeta] (route :get pattern handler rmeta))
(defn HEAD [pattern handler &opt rmeta] (route :head pattern handler rmeta))
(defn POST [pattern handler &opt rmeta] (route :post pattern handler rmeta))
(defn PUT [pattern handler &opt rmeta] (route :put pattern handler rmeta))
(defn PATCH [pattern handler &opt rmeta] (route :patch pattern handler rmeta))
(defn DELETE [pattern handler &opt rmeta] (route :delete pattern handler rmeta))
(defn OPTIONS [pattern handler &opt rmeta] (route :options pattern handler rmeta))
(defn ANY [pattern handler &opt rmeta] (route :any pattern handler rmeta))

(defn group
  "Group child routes under a path prefix and a metadata layer."
  [prefix gmeta & children]
  (unless (string? prefix)
    (errorf "group prefix must be a string, got %q" prefix))
  {:group true :prefix prefix :meta (or gmeta {}) :children children})

(defn routes
  "A route source: a global metadata layer over child routes/groups."
  [global & children]
  (unless (dictionary? global)
    (errorf "routes expects a global metadata dictionary first, got %q" global))
  {:routes true :global global :children children})

# -- pattern compilation -------------------------------------------------

(defn compile-pattern
  ``Compile "/orders/:id/files/*path" into {:params [:id :path] :peg
  <compiled> :static <path or nil>}. `:seg` captures one non-empty
  segment, `*seg` (terminal only) captures the rest including slashes;
  a pattern without captures is static — matched by table lookup, no
  PEG at all.``
  [pattern]
  (def params @[])
  (def parts @[])
  (var splat false)
  (def segs (string/split "/" (string/slice pattern 1)))
  (each seg segs
    (when splat
      (errorf "route pattern %q: *splat must be the last segment" pattern))
    (cond
      (string/has-prefix? ":" seg)
      (do
        (when (= ":" seg)
          (errorf "route pattern %q: empty :param name" pattern))
        (array/push params (keyword (string/slice seg 1)))
        (array/push parts ~(<- (some (if-not "/" 1)))))

      (string/has-prefix? "*" seg)
      (do
        (when (= "*" seg)
          (errorf "route pattern %q: empty *splat name" pattern))
        (array/push params (keyword (string/slice seg 1)))
        (array/push parts ~(<- (any 1)))
        (set splat true))

      (array/push parts seg)))
  (if (empty? params)
    {:params [] :peg nil :static pattern}
    (do
      (def body @[])
      (each p parts
        (array/push body "/")
        (array/push body p))
      {:params (tuple ;params)
       :peg (peg/compile ~(* ,;body -1))
       :static nil})))

# -- flattening sources --------------------------------------------------

(defn env-ref
  ``Wrap a module environment for a route-source :env inside a plugin
  manifest: manifests are frozen, and freezing a raw env table would
  walk the entire module graph (cycles included). The closure freezes
  as an opaque value; build-table unwraps it.

      :contributes {:void.http/route-source
                    [{:name :my/app :routes my-routes
                      :env (router/env-ref (curenv))}]}``
  [env]
  (fn wrapped-env [] env))

(defn- join-prefix [prefix pattern]
  (cond
    (empty? prefix) pattern
    (= "/" pattern) prefix
    (string prefix pattern)))

(defn- flatten-source
  "Walk one route source into flat declarations, each carrying its
  metadata layers [[label dict] ...] (global -> groups -> route) and
  the full pattern."
  [source-name form env out errors]
  (defn walk [node prefix layers]
    (cond
      (indexed? node)
      (each child node (walk child prefix layers))

      (not (dictionary? node))
      (array/push errors
                  (string/format "route source %q: expected a route, group, routes or tuple thereof, got %q"
                                 source-name node))

      (node :routes)
      (each child (node :children)
        (walk child prefix
              [;layers [[:global source-name] (node :global)]]))

      (node :group)
      (each child (node :children)
        (walk child
              (join-prefix prefix (node :prefix))
              [;layers [[:group (node :prefix)] (node :meta)]]))

      (node :route)
      (array/push out
                  {:method (node :method)
                   :pattern (join-prefix prefix (node :pattern))
                   :handler (node :handler)
                   :layers [;layers [:route (node :meta)]]
                   :env env
                   :source source-name})

      (array/push errors
                  (string/format "route source %q: expected a route, group or routes value, got %q"
                                 source-name node))))
  (walk form "" []))

# -- handler resolution (ADR-0002) ---------------------------------------

(defn- last-slash [s]
  (var i nil)
  (loop [j :down-to [(dec (length s)) 0] :until i]
    (when (= (chr "/") (s j)) (set i j)))
  i)

(defn resolve-handler
  ``Resolve a handler declaration to {:call <fn per dispatch> :fn
  <current fn> :no-reload <bool>} against `env` (the declaring module's
  environment, for bare symbols).

  A qualified symbol 'my-app.orders/show names binding `show` in module
  "my-app/orders" (dots become path separators); a bare symbol is
  looked up in `env`. Either way the resolved *environment table* is
  captured and the binding is read per call — module reloads that
  update the env in place (void/dev watch) are live without a rebuild.
  A function literal is called directly and marked :no-reload.``
  [handler &opt env]
  (cond
    (callable? handler)
    {:call (fn literal-handler [req] (handler req))
     :fn handler
     :no-reload true}

    (do
      (def s (string handler))
      (def i (last-slash s))
      (def [menv nm]
        (if i
          [(require (string/replace-all "." "/" (string/slice s 0 i)))
           (symbol (string/slice s (inc i)))]
          [(or env (errorf "cannot resolve bare handler symbol %q without a module environment — qualify it (my-app.orders/show)" handler))
           handler]))
      (def binding (get menv nm))
      (unless (and binding (callable? (get binding :value)))
        (errorf "handler %q does not resolve to a function%s"
                handler (if i "" " in the declaring module")))
      {:call (fn symbol-handler [req] ((in (in menv nm) :value) req))
       :fn (get binding :value)
       :no-reload false})))

# -- table build ---------------------------------------------------------

(def- allowed-build-opts
  {:sources true :meta-keys true :middleware true :strict true})

(defn build-table
  ``Build an immutable route table from route sources
  (ROADMAP 1.1; every failure across every route lands in one batched
  error):

      (router/build-table
        {:sources    [{:name :app :routes <routes value> :env (curenv)}]
         :meta-keys  <meta/declarations input — the resolved
                      :void.http/route-meta-key point>
         :middleware [{:plugin :void/http :value {:name ... :phase ...
                       :wrap ... :when ... :named ...}} ...]
         :strict     false})

  Per route this: compiles the pattern PEG, merges the metadata layers
  global -> group -> route (provenance kept for explain), requires
  :name (unique across the table), resolves the handler symbol fail-fast
  and composes the selected middleware into the route's chain. The
  result is a frozen value: {:routes :by-name :static :dynamic} —
  dispatch is a table lookup or an ordered PEG scan, nothing more.``
  [opts]
  (eachk k opts
    (unless (in allowed-build-opts k)
      (errorf "build-table: unknown option %q" k)))
  (def errors @[])
  (def decls
    (let [[ok d] (protect (meta/declarations (get opts :meta-keys {})))]
      (if ok d (do (array/push errors (string d)) {}))))
  (def contribs (get opts :middleware []))
  (def strict (get opts :strict false))

  # flatten every source
  (def flat @[])
  (each src (get opts :sources [])
    (unless (and (dictionary? src) (get src :routes))
      (errorf "build-table: each source must be {:name ... :routes <routes value>}, got %q" src))
    (def env
      (let [e (get src :env)]
        (if (callable? e) (e) e)))     # unwrap env-ref closures
    (flatten-source (get src :name :anonymous) (src :routes) env
                    flat errors))

  # build entries
  (def entries @[])
  (def by-name @{})
  (each d flat
    (def label (string/format "%q %s (source %q)" (d :method) (d :pattern) (d :source)))
    (def merged (meta/merge-layers decls (d :layers) {:strict strict}))
    (each e (merged :errors)
      (array/push errors (string/format "%s: %s" label e)))
    (def rmeta (merged :value))
    (def name (rmeta :name))
    (cond
      (nil? name)
      (array/push errors (string/format "%s: route :name is required" label))
      (not (keyword? name))
      (array/push errors (string/format "%s: route :name must be a keyword, got %q" label name))
      (in by-name name)
      (array/push errors (string/format "%s: route name %q is already taken by %s %s"
                                        label name
                                        (get-in by-name [name :method])
                                        (get-in by-name [name :pattern]))))
    (def [pat-ok compiled] (protect (compile-pattern (d :pattern))))
    (unless pat-ok
      (array/push errors (string/format "%s: %s" label (string compiled))))
    (def [h-ok resolved] (protect (resolve-handler (d :handler) (d :env))))
    (unless h-ok
      (array/push errors (string/format "%s: %s" label (string resolved))))
    (def [c-ok chain-or-err]
      (protect
        (let [selected (mw/select contribs rmeta)]
          {:chain (mw/chain selected (if h-ok (resolved :call) identity))
           :middleware (tuple ;(map |($ :name) selected))})))
    (unless c-ok
      (array/push errors (string/format "%s: %s" label (string chain-or-err))))
    (when (and (keyword? name) (not (in by-name name))
               pat-ok h-ok c-ok (empty? (merged :errors)))
      (def entry
        @{:name name
          :method (d :method)
          :pattern (d :pattern)
          :params (compiled :params)
          :peg (compiled :peg)
          :static (compiled :static)
          :handler (d :handler)
          :no-reload (resolved :no-reload)
          :meta (freeze rmeta)
          :provenance (freeze (merged :provenance))
          :warnings (merged :warnings)
          :chain (chain-or-err :chain)
          :middleware (chain-or-err :middleware)
          :source (d :source)})
      (put by-name name entry)
      (array/push entries entry)))

  (unless (empty? errors)
    (errorf "route table errors:\n  - %s" (string/join errors "\n  - ")))

  # indexes: static lookup per method, ordered dynamic scan per method
  (def static @{})
  (def dynamic @{})
  (each e entries
    (if (e :static)
      (do
        (def m (or (get static (e :method))
                   (let [t @{}] (put static (e :method) t) t)))
        (when (in m (e :static))
          (errorf "routes %q and %q both match %q %s"
                  (get-in m [(e :static) :name]) (e :name)
                  (e :method) (e :static)))
        (put m (e :static) e))
      (do
        (def arr (or (get dynamic (e :method))
                     (let [a @[]] (put dynamic (e :method) a) a)))
        (array/push arr e))))

  (freeze
    {:routes (tuple ;entries)
     :by-name by-name
     :static static
     :dynamic dynamic}))

# -- matching and dispatch -----------------------------------------------

(defn- match-method [table method path]
  (or (when-let [e (get-in table [:static method path])]
        [e {}])
      (label found
        (each e (get-in table [:dynamic method] [])
          (when-let [caps (peg/match (e :peg) path)]
            (return found
                    [e (freeze (tabseq [i :range [0 (length (e :params))]]
                                 (get (e :params) i) (get caps i)))])))
        nil)))

(defn match
  ``Match method + path against the table. Returns [entry params] or
  nil. :head falls back to :get (automatic HEAD), any method falls back
  to :any routes.``
  [table method path]
  (or (match-method table method path)
      (when (= :head method) (match-method table :get path))
      (match-method table :any path)))

(defn allowed-methods
  "The methods that would match this path — the 405 Allow list. Empty
  means 404."
  [table path]
  (def out @[])
  (each m (sorted (keys methods))
    (unless (= :any m)
      (when (match table m path)
        (array/push out m))))
  (freeze out))

(defn dispatch
  ``Match the request and run it through the route's precompiled chain.
  The entry lands in (req :void/route), captures in (req :params).
  Returns the response, or nil when no route matches.``
  [table req]
  (when-let [[entry params] (match table (req :method) (req :path))]
    (put req :void/route entry)
    (put req :params params)
    ((entry :chain) req)))

# -- reverse routing -----------------------------------------------------

(defn url-for
  ``Reverse routing by route name:

      (url-for table :orders/show {:id "42"})          # "/orders/42"
      (url-for table :orders/index nil {:page 2})       # "/orders?page=2"

  Path params are percent-encoded (a *splat keeps its slashes); a
  missing param or unknown name is an error.``
  [table name &opt params query]
  (def e (or (get-in table [:by-name name])
             (errorf "unknown route name %q (known: %s)"
                     name (string/join (map |(string/format "%q" $)
                                            (sorted (keys (table :by-name))))
                                       " "))))
  (def out @"")
  (each seg (string/split "/" (string/slice (e :pattern) 1))
    (buffer/push out "/")
    (cond
      (string/has-prefix? ":" seg)
      (let [k (keyword (string/slice seg 1))
            v (get params k)]
        (when (nil? v)
          (errorf "url-for %q: missing param %q" name k))
        (buffer/push out (wire/url-encode (string v))))

      (string/has-prefix? "*" seg)
      (let [k (keyword (string/slice seg 1))
            v (get params k)]
        (when (nil? v)
          (errorf "url-for %q: missing param %q" name k))
        (buffer/push out
                     (string/join (map wire/url-encode (string/split "/" (string v)))
                                  "/")))

      (buffer/push out seg)))
  (string out
          (if (and query (not (empty? query)))
            (string "?" (wire/encode-query query))
            "")))

# -- explain -------------------------------------------------------------

(defn explain-route
  ``The routing verdict for a path — the matched entry plus the origin
  of every metadata value by layer (ROADMAP 1.1, ADR-0005):

      (explain-route table "/admin/users")
      (explain-route table "/orders/42" :post)

  Returns {:name :method :pattern :params :handler :no-reload :meta
  :layers {key [{:source :value} ...]} :source :middleware :warnings
  :text <human summary>} or nil when nothing matches. :middleware is
  the resolved chain for this route (outermost first), :source the
  route-source contribution it came from, :warnings the bare-key
  warnings from the metadata merge.``
  [table path &opt method]
  (default method :get)
  (when-let [[e params] (match table method path)]
    (def merge-result {:value (e :meta) :provenance (e :provenance)})
    (def lines @[])
    (each k (sorted (keys (e :meta)))
      (array/push lines (meta/explain-str merge-result k)))
    (def warnings (get e :warnings []))
    {:name (e :name)
     :method (e :method)
     :pattern (e :pattern)
     :params params
     :handler (e :handler)
     :no-reload (e :no-reload)
     :meta (e :meta)
     :layers (e :provenance)
     :source (e :source)
     :middleware (e :middleware)
     :warnings warnings
     :text (string/format "%q %s -> %q (handler %q, source %q)\n  middleware: %s\n  %s%s"
                          (e :method) (e :pattern) (e :name) (e :handler)
                          (e :source)
                          (if (empty? (e :middleware))
                            "none"
                            (string/join (map |(string/format "%q" $) (e :middleware)) " -> "))
                          (string/join lines "\n  ")
                          (if (empty? warnings)
                            ""
                            (string "\n  warnings:\n    "
                                    (string/join warnings "\n    "))))}))

# -- atomic swap ---------------------------------------------------------

(defn cell
  "A one-slot holder for the current route table — the running server
  reads it per request; `swap!` replaces the table atomically."
  [&opt table]
  @{:table table})

(defn swap!
  "Atomically replace the table a cell holds. Returns the new table."
  [c table]
  (put c :table table)
  table)

(defn current
  "The table a cell currently holds."
  [c]
  (c :table))
