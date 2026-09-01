### void/mcp — the application as an MCP server (SPEC.md §5.18,
### ADR-0031).
###
### The promise of §5.18 is one sentence: "админка из коробки — это
### AI-агент". What makes it cheap is that the application has already
### said everything an agent needs. Its operational verbs are
### `:void.core/cli` commands, its data shapes are registered schemas,
### its liveness is the health report the core folds for `GET /health`.
### This plugin is the projection of those three into MCP's vocabulary
### — tools, resources, and a handshake — and it introduces no fourth
### declaration for anybody to keep in sync.
###
###     $ void mcp tools          # what an agent would see
###     $ void mcp serve          # speak MCP on stdin/stdout
###
### **Read-only by default, and the default is structural.** A command
### is exposed when it declared `:read-only? true`; a command that
### said nothing is not exposed, because nothing about a command's
### name says whether running it is safe, and guessing on behalf of an
### agent is how `db rollback` becomes a tool. Everything else waits
### to be named in `[:mcp :tools]` by the operator who wants it —
### which is the allowlist SPEC asks for, made of the same keywords
### `void <command>` uses.
###
### **What lives where.** ./jsonrpc is the wire format, ./server is
### the MCP methods over a server value, ./registry is the projection
### that builds one out of a boot, ./stdio is the transport that owns
### a process's stdin. `void/mcp-http` (./http) is the second
### transport and a separate plugin — a jobs worker exposing tools to
### an agent over stdio has no reason to drag the HTTP kernel in, the
### void/cache — void/cache-http split again. `void/mcp-obs` (./obs)
### publishes this process's metrics as a resource and is separate for
### the same reason.
###
### **What it is not.** No sampling, no elicitation, no roots, no
### prompts: every one of those needs the server to ask the client
### something, which needs a session pinned to a process, which is the
### state ADR-0031 refuses to keep so that two replicas behind a load
### balancer answer the same way. And no config resource, redacted or
### otherwise — a secret that leaks through a redaction bug is not
### worth the convenience of reading `[:db :host]` from a chat window.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import ./registry :as registry)
(import ./server :as server)
(import ./stdio :as stdio)

(def log-ns "void.mcp")

# -- extension points ----------------------------------------------------

(plugin/defextension-point :void.mcp/tool
  :doc "Tools that are not CLI commands: {:name :mcp/thing :doc ... :title ... :read-only? true|false :schema <void schema of the arguments> :needs [component-keys] :fn (fn [;instances arguments] string | {:text ... :error? bool})}. The gate is the same one commands pass: a tool that does not declare itself read-only is exposed only when [:mcp :tools] names it. A contribution may instead carry {:name ... :expand (fn [boot] [tool ...])} — one *projection* of something bootstrap resolved, for a plugin whose tools are derived from a registry the application fills long after its manifest froze (void/admin-mcp turns every declared admin resource into tools this way). An expansion yields ordinary tools and passes the same gate"
  :schema {:name :keyword
           :fn [:optional [:or :function :symbol]]
           :expand [:optional :function]
           :doc [:optional :string]
           :title [:optional :string]
           :read-only? [:optional :boolean]
           :schema [:optional :any]
           :needs [:optional [:vector :keyword]]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (unless (or (c :fn) (c :expand))
                  (errorf "MCP tool %q: needs a :fn, or an :expand that projects tools" (c :name)))
                (when (and (c :fn) (c :expand))
                  (errorf "MCP tool %q: :fn and :expand are two answers to one question" (c :name)))
                (when (in seen (c :name))
                  (errorf "duplicate MCP tool %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.mcp/resource
  :doc "Readable resources beyond the schemas and the health report: {:name :void.obs/metrics :uri \"void://metrics\" :doc ... :mime-type ... :needs [component-keys] :read (fn [;instances] string | {:text ... :mime-type ...})}. Resources are read-only by construction, so they need no allowlist — [:mcp :hide] withholds one by name. As with :void.mcp/tool, a contribution may instead carry {:name ... :expand (fn [boot] [resource ...])}: one projection of a registry the application fills after this manifest froze"
  :schema {:name :keyword
           :uri [:optional :string]
           :read [:optional [:or :function :symbol]]
           :expand [:optional :function]
           :doc [:optional :string]
           :title [:optional :string]
           :mime-type [:optional :string]
           :needs [:optional [:vector :keyword]]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (unless (or (c :expand) (and (c :uri) (c :read)))
                  (errorf "MCP resource %q: needs a :uri and a :read, or an :expand that projects resources"
                          (c :name)))
                (when-let [uri (c :uri)]
                  (when (in seen uri)
                    (errorf "two MCP resources claim the URI %q" uri))
                  (put seen uri true))))
  :reduce |(sorted-by |(string (get $ :uri (get $ :name))) $))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:mcp] config slice."
  {:read-only [:optional :boolean]
   :tools [:optional [:vector :keyword]]
   :hide [:optional [:vector :keyword]]
   :schemas [:optional [:or :boolean [:vector :keyword]]]
   :health [:optional :boolean]
   :name [:optional :string]
   :version [:optional :string]
   :instructions [:optional :string]})

(def defaults registry/defaults)

(var settings
  "The [:mcp] slice, read at :before-start."
  registry/defaults)

(var boot-ref
  "The boot value this process's projection reads. One per process,
  like plugin/current-boot — a tool call resolves its components
  through it."
  nil)

(defn- boot []
  (or boot-ref
      (error "void/mcp is not booted — add :void/mcp to :plugins (the projection is built at :before-start)")))

(defn build-settings
  "The [:mcp] slice over the defaults, checked against the
  composition. Normally called by the :before-start hook."
  [b]
  (def cfg (merge registry/defaults (or (get-in b [:config :values :mcp]) {})))
  (registry/check-settings! b cfg)
  # an MCP server is not a tool of itself: allowlisting `mcp serve`
  # would hand an agent the ability to start a second server on a
  # stdin nobody is holding
  (when (index-of :mcp/serve (get cfg :tools []))
    (error "[:mcp :tools] names :mcp/serve — an MCP server cannot be one of its own tools"))
  cfg)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :mcp/capture-config
   :doc "Read the [:mcp] slice and check the allowlist against the composition's commands"
   :fn (fn capture [b]
         (set boot-ref b)
         (set settings (build-settings b)))})

# -- the projection ------------------------------------------------------

(defn server-value
  ``The server value for this process (see ./server for the shape) —
  built per call, so a command contributed by a hot-reloaded plugin is
  a tool without a restart. `opts` :start-needs says whether a tool
  may start the components it needs.``
  [&opt opts]
  (registry/build (boot) settings (or opts {})))

(defn exposed
  "What this composition exposes, as data: {:tools [names] :resources
  [uris]} — what `void mcp tools` prints and what the suite asserts on."
  [&opt opts]
  (def srv (server-value opts))
  {:tools (map |($ :name) (srv :tools))
   :resources (map |($ :uri) (srv :resources))})

(defn handle
  "Answer one decoded JSON-RPC message against this process's
  projection — the entry point both transports share."
  [msg &opt opts]
  (server/handle (server-value opts) msg))

# -- commands ------------------------------------------------------------

(defn print-tools
  "The body of `void mcp tools`: what an agent connecting right now
  would see, and — for every command that is not there — the reason."
  []
  (def b (boot))
  (def srv (server-value))
  (print "MCP server: " (get-in srv [:info :name]) " " (get-in srv [:info :version]))
  (print)
  (print "Tools (" (length (srv :tools)) "):")
  (each t (srv :tools)
    (printf "  %-24s %s%s"
            (t :name)
            (if (t :read-only?) "" "(writes) ")
            (get t :description "")))
  (when (empty? (srv :tools))
    (print "  none — no command in this composition declared :read-only? true,")
    (print "  and [:mcp :tools] names none. An agent connecting now can read"))
  (print)
  (print "Withheld:")
  (var withheld 0)
  (each cmd (get-in b [:extensions :void.core/cli :resolved] [])
    (unless (registry/exposed? settings cmd)
      (++ withheld)
      (printf "  %-24s %s"
              (registry/tool-name (cmd :name))
              (cond
                (= :mcp/serve (cmd :name)) "this is the server itself"
                (index-of (cmd :name) (get settings :hide [])) "hidden by [:mcp :hide]"
                (false? (get cmd :read-only?))
                "declared that it writes — name it in [:mcp :tools] to expose it anyway"
                "says nothing about whether it writes — declare :read-only? on it, or name it in [:mcp :tools]"))))
  (when (zero? withheld) (print "  nothing"))
  (print)
  (print "Resources (" (length (srv :resources)) "):")
  (each r (srv :resources)
    (printf "  %-40s %s" (r :uri) (get r :description "")))
  nil)

(plugin/contribute! :void.core/cli
  {:name :mcp/tools
   :doc "Show what this composition exposes over MCP, and what it withholds: void mcp tools"
   :read-only? true
   :fn (fn cli-tools [& _] (print-tools))})

(plugin/contribute! :void.core/cli
  {:name :mcp/serve
   :doc "Speak MCP over stdin/stdout, one JSON-RPC message per line: void mcp serve"
   # not read-only, and deliberately not exposable (see build-settings):
   # this is the command that *is* the server
   :read-only? false
   :fn (fn cli-serve [& _]
         (log/info "mcp stdio server starting" :ns log-ns
                   :tools (length (get (server-value {:start-needs true}) :tools)))
         (stdio/serve (fn stdio-handle [msg]
                        (handle msg {:start-needs true}))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/mcp
  :doc "The application as an MCP server: :void.core/cli commands projected into tools, registered schemas and the health report into resources, JSON-RPC over stdio. Read-only by default — a command is a tool only if it declared itself read-only or an operator allowlisted it."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :mcp
  :config-schema Config
  :config-defaults registry/defaults)
