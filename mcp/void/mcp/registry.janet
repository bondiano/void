### void/mcp/registry — the projection: a booted composition in, the
### server value ./server dispatches on out.
###
### **Nothing here is a second declaration.** A tool is a
### `:void.core/cli` command — the same command a human runs as `void
### db status`, with the same `:needs`, the same function and the same
### output; a resource is a registered schema (as JSON Schema, through
### void/openapi's projection module), the health report the core
### folds for `GET /health`, or something a plugin contributed to
### `:void.mcp/resource`. An application that adds a command gets a
### tool; one that registers a schema gets a resource; neither writes
### anything twice, and neither can drift.
###
### **The gate is one question asked of everything.** A command says
### `:read-only? true` or it does not, and what does not say it is not
### exposed until the operator names it in `[:mcp :tools]`. The
### default is therefore read-only *by construction* rather than by a
### list somebody has to maintain: a plugin added tomorrow, whose
### commands nobody has classified, exposes nothing. Silence means
### "unknown", and unknown never reaches an agent.
###
### **A command's interface is argv, and the projection says so.** The
### input schema of a command tool is `{"args": ["--limit", "5"]}` —
### the strings the command would have got from the shell, unchanged.
### Inventing named parameters would mean parsing every command's flag
### grammar out of its docstring and guessing at the rest; a plugin
### that wants a richer shape contributes `:void.mcp/tool` with a
### schema instead, and that tool is validated and coerced by
### void/core/schema like any other input.
###
### **stdout belongs to the answer.** A command prints; a tool
### returns. The projection binds `:out` to a buffer for the length of
### the call, so what the command wrote is what the model reads — and
### on the stdio transport that same binding is what keeps a
### command's output out of the protocol's own stream.

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/core/system :as system)
(import void/openapi/jsonschema :as jsonschema)

(def defaults
  ``Defaults of the [:mcp] slice. `:read-only` true is the whole
  security posture: every command that declared itself read-only is a
  tool, everything else waits to be named in `:tools`.``
  {:read-only true
   :tools []
   :hide []
   :schemas true
   :health true
   :name "void"
   :version "0.0.1"})

(def instructions
  ``The preamble a client shows the model. It says the two things a
  model cannot infer from the tool list: what these tools are (the
  application's own operational commands, not a general shell) and
  that the absence of a tool is a decision rather than an oversight.``
  (string
    "These tools are the operational commands of a running void application — "
    "the same commands its operators run from the `void` binary, with the same "
    "arguments. Each takes an `args` array of command-line arguments and returns "
    "what the command printed.\n"
    "Only commands that declared themselves read-only are exposed by default; "
    "anything that changes state had to be allowlisted by an operator, so a "
    "command you expect and cannot find was deliberately withheld.\n"
    "Resources carry the application's registered schemas as JSON Schema and the "
    "health of the process."))

# -- names ---------------------------------------------------------------

(defn tool-name
  ``The MCP name of a command: `:db/status` -> "db_status". Clients
  and models alike expect `[a-z0-9_-]`, and the slash a namespaced
  command keyword carries is not in it.``
  [name]
  (string/replace-all "/" "_" (string name)))

(defn schema-uri
  "The URI a registered schema is published under."
  [name]
  (string "void://schema/" name))

# -- running a command ---------------------------------------------------

(defn- callable
  ``The function of a contribution under `key`, or a readable refusal —
  symbols are late-bound and nothing resolves them for CLI commands yet,
  so say that rather than call a symbol.``
  [entry &opt key]
  (default key :fn)
  (def f (entry key))
  (when (symbol? f)
    (errorf "%q: %q is the symbol %q — contribute a function, symbol resolution is not wired for commands"
            (entry :name) key f))
  f)

(defn- instances
  ``The `:needs` instances of a command, in declaration order.

  `:start` decides what happens when a needed component is not
  running: the stdio transport passes true (the process exists to
  serve this call and nothing is up yet — the same thing `void
  <command>` does), the HTTP transport does not (its process is
  already serving, and a request must not start a database pool as a
  side effect of a tool call).``
  [boot needs start?]
  (def sys (boot :system))
  (def missing
    (filter |(nil? (get-in sys [:instances $])) (or needs [])))
  (when (and start? (not (empty? missing)))
    (system/start sys missing))
  (def still (filter |(nil? (get-in sys [:instances $])) (or needs [])))
  (unless (empty? still)
    (errorf "component%s %s %s not running — this tool needs %s"
            (if (= 1 (length still)) "" "s")
            (string/join (map string still) ", ")
            (if (= 1 (length still)) "is" "are")
            (string/join (map string (or needs [])) ", ")))
  (map |(get-in sys [:instances $]) (or needs [])))

(defn- argv
  ``The `args` of a tool call as strings. An array is the declared
  shape; a bare string is what a model that thinks in command lines
  sends, and splitting it on whitespace is a better answer than
  refusing the call it obviously meant.``
  [arguments]
  (def given (get arguments :args))
  (cond
    (nil? given) []
    (string? given) (filter |(not (empty? $)) (string/split " " given))
    (indexed? given)
    (map (fn [a]
           (unless (or (string? a) (number? a) (keyword? a))
             (errorf "args must be strings, got %q" a))
           (string a))
         given)
    (errorf "args must be an array of strings, got %q" given)))

(defn- rendered
  "What a call answers with: what it printed, or — when it printed
  nothing — what it returned."
  [out value]
  (cond
    (not (empty? out)) (string out)
    (nil? value) "(no output)"
    (string? value) value
    (string/format "%q" value)))

(defn run-command
  ``Run a CLI command as a tool call: resolve its `:needs`, bind
  `:out` to a buffer, call it with the instances followed by the
  argument strings, and answer with what it printed.

  Returns {:text ... :error? bool} — ./server turns a failure into a
  result with `isError`, because the model is the reader of it.``
  [boot cmd arguments &opt opts]
  (default opts {})
  (def out (or (get opts :out) @""))
  (def [ok value]
    (protect
      (let [f (callable cmd)
            args (argv (or arguments @{}))
            inst (instances boot (get cmd :needs []) (get opts :start-needs false))]
        (with-dyns [:out out]
          (f ;inst ;args)))))
  (if ok
    {:text (rendered out value) :error? false}
    {:text (string (if (string? value) value (describe value))
                   (if (empty? out) "" (string "\n\n" out)))
     :error? true}))

(defn run-tool
  ``Run a `:void.mcp/tool` contribution. Its arguments are validated
  (and coerced) against its `:schema` first, so a tool written for MCP
  gets what every other void input gets: one declaration, validation
  from it, and errors with a path.``
  [boot tool arguments &opt opts]
  (default opts {})
  (def out (or (get opts :out) @""))
  (def [ok value]
    (protect
      (let [f (callable tool)
            args (if-let [sch (get tool :schema)]
                   (schema/coerce sch (or arguments @{}))
                   (or arguments @{}))
            inst (instances boot (get tool :needs []) (get opts :start-needs false))]
        (with-dyns [:out out]
          (f ;inst args)))))
  (cond
    (not ok)
    {:text (string (if (string? value) value (describe value))
                   (if (empty? out) "" (string "\n\n" out)))
     :error? true}
    (dictionary? value) {:text (get value :text (rendered out nil))
                         :error? (true? (get value :error?))}
    {:text (rendered out value) :error? false}))

# -- contributions, with projections flattened ---------------------------
#
# A contribution either *is* a tool (or a resource) or *projects* a list
# of them from the boot value. The second form exists because a plugin
# whose tools come from a registry the application fills — void/admin-mcp
# and its resource declarations — has nothing to put in its manifest at
# the moment the manifest freezes. It is the same shape, and the same
# reason, as :void.http/route-source taking a function.

(defn- provenance
  ``Which plugin contributed each entry of one point, by the entry's
  :name — read off the contribution wrappers, because the resolved
  values bootstrap hands on no longer say where they came from.``
  [boot point]
  (tabseq [c :in (get-in boot [:extensions point :contributions] [])]
    (get-in c [:value :name]) (c :plugin)))

(defn- expanded
  "The contributions of one point, with every :expand applied, and each
  entry carrying the plugin it came from."
  [boot point what]
  (def who (provenance boot point))
  (def out @[])
  (each c (get-in boot [:extensions point :resolved] [])
    (if-let [f (get c :expand)]
      (let [[ok v] (protect (f boot))]
        (unless ok
          (errorf "%s %q: projecting its %ss failed: %s" what (c :name) what v))
        # a projected entry answers for its provenance the same way a
        # direct one does: by the plugin whose contribution it came from
        (each e v (array/push out (if (get e :plugin)
                                    e
                                    (merge e {:plugin (get who (c :name))})))))
      (array/push out (if (get c :plugin)
                        c
                        (merge c {:plugin (get who (c :name))})))))
  out)

(defn contributed-tools
  "Every :void.mcp/tool this composition has, projections included."
  [boot]
  (expanded boot :void.mcp/tool "MCP tool"))

(defn contributed-resources
  "Every :void.mcp/resource this composition has, projections included."
  [boot]
  (expanded boot :void.mcp/resource "MCP resource"))

# -- what is exposed -----------------------------------------------------

(defn- hidden? [settings name]
  (truthy? (index-of name (get settings :hide []))))

(defn- allowlisted? [settings name]
  (truthy? (index-of name (get settings :tools []))))

(defn exposed?
  ``The gate, in one place: a declaration is exposed when it says it
  is read-only (and `[:mcp :read-only]` is on), or when the operator
  named it in `[:mcp :tools]`; `[:mcp :hide]` wins over both, so a
  read-only command can still be withheld without touching the plugin
  that declared it.

  **`:read-only? true` is the declaration's own claim, and nothing
  verifies it.** Any plugin in the composition can mark a command
  read-only and have it exposed to an agent without an operator naming
  it — the gate keeps the *unclassified* out, not the misclassified.
  Reviewing that claim when a plugin is added is part of the posture,
  and `void mcp tools` prints each tool's contributing plugin so the
  review has something to read.``
  [settings entry]
  (def name (entry :name))
  (and (not (hidden? settings name))
       (or (allowlisted? settings name)
           (and (get settings :read-only true)
                (true? (get entry :read-only?))))))

(defn command-names
  "Every CLI command in this composition, whether exposed or not — the
  vocabulary `[:mcp :tools]` is checked against."
  [boot]
  (map |($ :name) (get-in boot [:extensions :void.core/cli :resolved] [])))

(defn contributed-tool-names
  "Every :void.mcp/tool in this composition."
  [boot]
  (map |($ :name) (contributed-tools boot)))

(def- command-input-schema
  ``The input schema of every command tool: argv, and nothing
  invented. `additionalProperties` false because a model that passes
  something else has misunderstood the tool, and the sooner it hears
  so the fewer turns it spends.``
  {"type" "object"
   "properties" {"args" {"type" "array"
                         "items" {"type" "string"}
                         "description" "Command-line arguments, exactly as the `void` binary takes them"}}
   "additionalProperties" false})

(defn- annotations [entry title]
  (def read-only (true? (get entry :read-only?)))
  @{:title title
    :readOnlyHint read-only
    # a command that was allowlisted despite not declaring itself
    # read-only is, as far as anything here knows, destructive — and
    # the hint exists so a client can ask a human before running it
    :destructiveHint (not read-only)
    :openWorldHint false})

(defn command-tool
  "One CLI command as an MCP tool."
  [boot cmd opts]
  (def name (tool-name (cmd :name)))
  # the title is the command line a human would have typed, which is
  # the most useful thing a client can show next to the tool
  (def title (string "void " (string/replace-all "/" " " (string (cmd :name)))))
  @{:name name
    :title title
    :description (get cmd :doc (string "The `" name "` command of this application"))
    :input-schema command-input-schema
    :annotations (annotations cmd title)
    :read-only? (true? (get cmd :read-only?))
    # who contributed the command this tool runs — `void mcp tools`
    # prints it, so the self-declared :read-only? has a reviewable source
    :plugin (get cmd :plugin)
    :call (fn call-command [arguments &opt out]
            (run-command boot cmd arguments (merge opts {:out out})))})

(defn contributed-tool
  "One :void.mcp/tool contribution as an MCP tool."
  [boot tool opts]
  (def name (tool-name (tool :name)))
  @{:name name
    :title (get tool :title name)
    :description (get tool :doc "")
    :input-schema (if-let [sch (get tool :schema)]
                    (jsonschema/json-schema sch)
                    @{"type" "object"})
    :annotations (annotations tool (get tool :title name))
    :read-only? (true? (get tool :read-only?))
    :plugin (get tool :plugin)
    :call (fn call-tool [arguments &opt out]
            (run-tool boot tool arguments (merge opts {:out out})))})

(defn tools
  "Every tool this composition exposes, sorted by name: the CLI
  commands that pass the gate, then the :void.mcp/tool contributions
  that do."
  [boot settings &opt opts]
  (default opts {})
  (def who (provenance boot :void.core/cli))
  (def out @[])
  (each cmd (get-in boot [:extensions :void.core/cli :resolved] [])
    (when (exposed? settings cmd)
      (def t (command-tool boot cmd opts))
      (unless (t :plugin) (put t :plugin (get who (cmd :name))))
      (array/push out t)))
  (each t (contributed-tools boot)
    (when (exposed? settings t)
      (array/push out (contributed-tool boot t opts))))
  (sorted-by |($ :name) out))

# -- resources -----------------------------------------------------------

(defn schema-document
  ``One registered schema as a standalone JSON Schema document. The
  refs it reaches are resolved into `components/schemas` — the same
  pointer void/openapi writes, and it resolves inside this document
  because the document carries the target.``
  [name]
  (def sch (or (schema/lookup name) (errorf "schema %q is not registered" name)))
  (def refs @{})
  (def doc (jsonschema/convert sch refs))
  (put doc "title" (string name))
  (unless (empty? refs)
    (put doc "components" @{"schemas" (jsonschema/components refs)}))
  doc)

(defn schema-names
  ``The schemas exposed as resources: every registered one
  (`[:mcp :schemas]` true, the default), a named subset, or none.``
  [settings]
  (def want (get settings :schemas true))
  (cond
    (false? want) []
    (indexed? want) (filter |(not (nil? (schema/lookup $))) want)
    (schema/registered)))

(defn schema-resources
  "The registered schemas as resources."
  [settings]
  (seq [name :in (schema-names settings)]
    @{:uri (schema-uri name)
      :name (string name)
      :title (string name)
      :description (string "The `" name "` schema of this application, as JSON Schema")
      :mime-type "application/schema+json"
      :read (fn read-schema [] (json/encode (schema-document name)))}))

(defn health-resource
  ``The process's health as a resource — `plugin/health`, the same
  fold `GET /health` renders (void/obs-http), so an agent and a load
  balancer read one report rather than two.``
  [boot]
  @{:uri "void://health"
    :name "health"
    :title "health"
    :description "Health of this process: every component's check and the aggregate"
    :mime-type "application/json"
    :read (fn read-health [] (json/encode (plugin/health boot)))})

(defn contributed-resource
  "One :void.mcp/resource contribution as a resource."
  [boot res opts]
  @{:uri (res :uri)
    :name (string (res :name))
    :title (get res :title (string (res :name)))
    :description (get res :doc "")
    :mime-type (get res :mime-type "text/plain")
    :read (fn read-contributed []
            (def f (callable res :read))
            (def inst (instances boot (get res :needs [])
                                 (get opts :start-needs false)))
            (f ;inst))})

(defn resources
  "Every resource this composition publishes, sorted by URI."
  [boot settings &opt opts]
  (default opts {})
  (def out @[])
  (when (get settings :health true)
    (array/push out (health-resource boot)))
  (array/concat out (schema-resources settings))
  (each res (contributed-resources boot)
    (unless (hidden? settings (res :name))
      (array/push out (contributed-resource boot res opts))))
  (sorted-by |($ :uri) out))

# -- the server value ----------------------------------------------------

(defn build
  ``The server value for a booted composition (see ./server for its
  shape). `opts` :start-needs says whether a tool may start the
  components it needs — true on stdio, false in a serving process.``
  [boot settings &opt opts]
  (default opts {})
  @{:info @{:name (get settings :name "void")
            :version (get settings :version "0.0.1")}
    :instructions (get settings :instructions instructions)
    :tools (tools boot settings opts)
    :resources (resources boot settings opts)})

# -- the allowlist is checked before anything runs -----------------------

(defn check-settings!
  ``Refuse a `[:mcp :tools]` or `[:mcp :hide]` entry that names
  nothing: a typo in an allowlist is a tool silently missing from an
  agent's toolbox, and there is no later moment at which anybody finds
  out. Called from the :before-start hook, so it fails the boot with
  the vocabulary in the message.``
  [boot settings]
  (def known (array ;(command-names boot) ;(contributed-tool-names boot)))
  (def resources-known
    (map |($ :name) (contributed-resources boot)))
  (def errs @[])
  (each name (get settings :tools [])
    (unless (index-of name known)
      (array/push errs (string/format "[:mcp :tools] names %q, which is not a command or tool of this composition" name))))
  (each name (get settings :hide [])
    (unless (or (index-of name known) (index-of name resources-known))
      (array/push errs (string/format "[:mcp :hide] names %q, which is not a command, tool or resource of this composition" name))))
  (unless (empty? errs)
    (errorf "%s\n  known: %s"
            (string/join errs "\n")
            (string/join (sorted (map string known)) " ")))
  settings)
