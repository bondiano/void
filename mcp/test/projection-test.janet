### The projection and its gate: which of a composition's commands reach
### an agent, what a tool call does with a command that prints, and what a
### typo in the allowlist costs.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/schema :as schema)
(import void/core/hooks :as hooks)
(import void/core/log :as log)
(import void/mcp :as mcp)
(import void/mcp/registry :as registry)
(import spork/json)

(log/set-level! "void" :error)

(schema/register! :Order {:id :int :title [:string {:min 1}]})
(schema/register! :Line {:order [:ref :Order] :qty [:int {:min 1}]})

(def started @[])

(def thing
  (system/component :test/thing
    :doc "A component a command needs"
    :start (fn [_ _] (array/push started :thing) @{:value 42})))

(defn- app []
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/mcp ">=0.0.1"}
    :components [thing]
    :contributes
    {:void.core/cli
     [{:name :test/read
       :doc "Prints and changes nothing"
       :read-only? true
       :fn (fn [& args] (printf "read %j" args) :returned)}
      {:name :test/write
       :doc "Changes the world"
       :read-only? false
       :fn (fn [& args] (print "wrote") nil)}
      {:name :test/silent
       :doc "Says nothing about itself"
       :fn (fn [& args] (print "silent") nil)}
      {:name :test/needy
       :doc "Needs a component"
       :read-only? true
       :needs [:test/thing]
       :fn (fn [t & args] (printf "thing is %d" (t :value)))}
      {:name :test/quiet
       :doc "Prints nothing at all"
       :read-only? true
       :fn (fn [& args] {:answer 1})}
      {:name :test/angry
       :doc "Throws"
       :read-only? true
       :fn (fn [& args] (error "no"))}]
     :void.mcp/tool
     [{:name :test/typed
       :doc "Takes typed arguments"
       :read-only? true
       :schema {:n :int}
       :fn (fn [args] (string "n is " (inc (args :n))))}]
     :void.mcp/resource
     [{:name :test/note
       :uri "void://note"
       :doc "A note"
       :mime-type "text/plain"
       :read (fn [] "the note")}]}))

(defn- boot-with [mcp-config]
  (def boot (plugin/bootstrap {:plugins [:void/mcp (app)]
                               :profile :test
                               :config {:env @{}
                                        :cli {:log {:level :error}
                                              :mcp mcp-config}}}
                              true))
  (hooks/run! (boot :hooks) :config-loaded boot)
  (hooks/run! (boot :hooks) :before-start boot)
  boot)

# -- the gate ------------------------------------------------------------

(def boot (boot-with {}))
(def exposed (mcp/exposed))

(assert (index-of "test_read" (exposed :tools))
        "a command that declared itself read-only is a tool")
(assert (not (index-of "test_write" (exposed :tools)))
        "a command that declared that it writes is not")
(assert (not (index-of "test_silent" (exposed :tools)))
        "and a command that said nothing is not either — silence is not consent")
(assert (index-of "test_typed" (exposed :tools))
        "a :void.mcp/tool passes the same gate, not a friendlier one")
(assert (index-of "mcp_tools" (exposed :tools))
        "this plugin's own read-only command is a tool like any other")
(assert (not (index-of "mcp_serve" (exposed :tools)))
        "and the command that *is* the server is not")

# the allowlist is the operator's, and it opens exactly what it names
(boot-with {:tools [:test/write]})
(assert (index-of "test_write" ((mcp/exposed) :tools))
        "[:mcp :tools] exposes a command that writes")
(assert (not (index-of "test_silent" ((mcp/exposed) :tools)))
        "and only the one it names")

# :hide wins over both, so a read-only command can be withheld without
# touching the plugin that declared it
(boot-with {:hide [:test/read]})
(assert (not (index-of "test_read" ((mcp/exposed) :tools)))
        "[:mcp :hide] withholds a read-only command")

# and the whole default can be turned off at once
(boot-with {:read-only false})
(assert (not (index-of "test_read" ((mcp/exposed) :tools)))
        "[:mcp :read-only] false exposes nothing that was not named")

# -- a typo in the allowlist is a boot failure ---------------------------

(each [cfg why]
  [[{:tools [:test/reed]} "a misspelled command in [:mcp :tools]"]
   [{:hide [:test/nothing]} "a misspelled name in [:mcp :hide]"]
   [{:tools [:mcp/serve]} "the server itself in [:mcp :tools]"]]
  (def [ok err] (protect (boot-with cfg)))
  (assert (not ok) (string why " fails the boot"))
  (assert (string? err) (string why " fails with a message")))

(def [_ err] (protect (boot-with {:tools [:test/reed]})))
(assert (string/find "test/read" err)
        "and the message carries the vocabulary the typo missed")

# -- a tool call is the command, unchanged -------------------------------

(def boot2 (boot-with {:tools [:test/write]}))

(defn- call [name args]
  (mcp/handle @{:id 1 :method "tools/call"
                :params @{:name name :arguments args}}))

(def read (call "test_read" @{:args ["--limit" "5"]}))
(assert (= `read ("--limit" "5")` (string/trim (get-in read [:result :content 0 :text])))
        "the command's arguments arrive as argv and its stdout is the answer")
(assert (= false (get-in read [:result :isError])) "and it did not fail")

# a model that types a command line means a command line
(def split (call "test_read" @{:args "--limit 5"}))
(assert (= `read ("--limit" "5")` (string/trim (get-in split [:result :content 0 :text])))
        "a single string of arguments is split into argv")

# a command that prints nothing still says something: what it returned
(assert (string/find "answer" (get-in (call "test_quiet" @{}) [:result :content 0 :text]))
        "a command that prints nothing answers with its return value")

# and one that throws comes back as a result the model can read
(def angry (call "test_angry" @{}))
(assert (get-in angry [:result :isError]) "a command that throws is a failed tool call")
(assert (string/find "no" (get-in angry [:result :content 0 :text])) "carrying its message")

# -- typed tools are validated and coerced by the schema layer -----------

(assert (= "n is 6" (get-in (call "test_typed" @{:n "5"}) [:result :content 0 :text]))
        "a :void.mcp/tool's arguments are coerced by its schema")
(def bad (call "test_typed" @{:n "not a number"}))
(assert (get-in bad [:result :isError]) "and a value the schema refuses fails the call")

# -- components a tool needs ---------------------------------------------
#
# Nothing is running here: `plugin/bootstrap` builds the graph and
# starts none of it, which is the state `void mcp serve` begins in.

(assert (empty? started) "no component started while the projection was built")

(def refused (call "test_needy" @{}))
(assert (get-in refused [:result :isError])
        "a tool whose component is not running says so rather than crashing")
(assert (string/find "test/thing" (get-in refused [:result :content 0 :text]))
        "and names the component")

(def allowed (mcp/handle @{:id 2 :method "tools/call"
                           :params @{:name "test_needy" :arguments @{}}}
                         {:start-needs true}))
(assert (string/find "42" (get-in allowed [:result :content 0 :text]))
        "with :start-needs the tool starts what it needs and runs")
(assert (= 1 (length started)) "and starts it exactly once")
(system/stop (boot2 :system))

# -- resources -----------------------------------------------------------

(def boot3 (boot-with {}))
(def uris ((mcp/exposed) :resources))
(assert (index-of "void://health" uris) "the health report is a resource")
(assert (index-of "void://schema/Order" uris) "so is every registered schema")
(assert (index-of "void://note" uris) "and so is a contributed one")

(defn- read-resource [uri]
  (get-in (mcp/handle @{:id 3 :method "resources/read" :params @{:uri uri}})
          [:result :contents 0]))

(def health (json/decode ((read-resource "void://health") :text) true))
(assert (= "up" (string (health :status)))
        "the health resource is the core's own report")

(def order (json/decode ((read-resource "void://schema/Order") :text)))
(assert (= "object" (order "type")) "a schema resource is JSON Schema")
(assert (= "Order" (order "title")) "titled with the name it is registered under")
(assert (index-of "id" (order "required")) "with its required fields")

# a schema that references another carries the target with it, so the
# document a client reads resolves inside itself
(def line (json/decode ((read-resource "void://schema/Line") :text)))
(assert (get-in line ["properties" "order" "$ref"]) "a reference stays a reference")
(assert (get-in line ["components" "schemas" "Order"])
        "and the document carries what it points at")

(assert (= "the note" ((read-resource "void://note") :text)) "a contributed resource reads")

# the schema resources are a slice the operator can narrow
(boot-with {:schemas false})
(assert (not (some |(string/has-prefix? "void://schema/" $) ((mcp/exposed) :resources)))
        "[:mcp :schemas] false publishes none of them")
(boot-with {:schemas [:Order]})
(assert (deep= @["void://schema/Order"]
               (filter |(string/has-prefix? "void://schema/" $) ((mcp/exposed) :resources)))
        "and a list publishes exactly those")

# -- the report an operator reads ----------------------------------------

(boot-with {})
(def out @"")
(with-dyns [:out out] (mcp/print-tools))
(assert (string/find "test_read" out) "`void mcp tools` prints what is exposed")
(assert (string/find "Withheld" out) "and what is not")
(assert (string/find "says nothing about whether it writes" out)
        "with the reason, per command")

# :read-only? is a plugin's own claim and nothing verifies it — so the
# report says whose claim each exposed tool rides on, and the projection
# carries the provenance for anything else that wants to ask
(assert (string/find "test/app" out)
        "every tool is printed with the plugin that contributed it")
(def srv (mcp/server-value))
(each name ["test_read" "test_typed"]
  (def t (find |(= name ($ :name)) (srv :tools)))
  (assert (= "test/app" (string (t :plugin)))
          (string name " knows which plugin declared it")))

(print "projection-test ok")
