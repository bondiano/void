### The composition: what validates, what refuses, and what a second
### replica would have to share (ADR-0031, ADR-0030).

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(require "void/http/init")
(require "void/mcp/init")
(require "void/mcp/http")
(require "void/obs/init")
(require "void/mcp/obs")
(import void/mcp :as mcp)
(import void/obs/metrics :as metrics)

(log/set-level! "void" :error)

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error} :http {:port 0}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report
  (plugin/dry-run {:plugins [:void/http :void/obs :void/mcp :void/mcp-http :void/mcp-obs]
                   :profile :test
                   :config (config {})}))
(assert (report :ok) "the three plugins of the package compose")
(assert (get-in report [:extensions :void.mcp/tool]) "and declare their extension points")
(assert (get-in report [:extensions :void.mcp/resource]) "both of them")

# -- the config slice is validated before anything answers ---------------

(each [slice reason]
  [[{:mcp {:read-only "yes"}} "a gate that is not a boolean"]
   [{:mcp {:tools :routes}} "an allowlist that is not a list"]
   [{:mcp {:hide ["routes"]}} "a hide list of strings rather than command names"]
   [{:mcp-http {:progress-interval 0}} "a progress interval of zero"]
   [{:mcp-http {:origins "https://x"}} "an origin list that is not a list"]]
  (def [ok] (protect (plugin/dry-run {:plugins [:void/http :void/mcp :void/mcp-http]
                                      :profile :test
                                      :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- two contributions cannot claim the same name ------------------------

(defn- with-contributions [contribs]
  (plugin/manifest 'clash/app
    :version "0.1.0"
    :requires {:void/mcp ">=0.0.1"}
    :contributes contribs))

(def [ok-tools]
  (protect (plugin/dry-run
             {:plugins [:void/mcp
                        (with-contributions
                          {:void.mcp/tool [{:name :a/thing :fn (fn [_] "")}
                                           {:name :a/thing :fn (fn [_] "")}]})]
              :profile :test
              :config (config {})})))
(assert (not ok-tools) "two tools under one name is a boot error")

(def [ok-uris]
  (protect (plugin/dry-run
             {:plugins [:void/mcp
                        (with-contributions
                          {:void.mcp/resource
                           [{:name :a/one :uri "void://same" :read (fn [] "")}
                            {:name :a/two :uri "void://same" :read (fn [] "")}]})]
              :profile :test
              :config (config {})})))
(assert (not ok-uris) "two resources under one URI is a boot error — a client picks by URI")

# -- void/mcp-obs publishes the exposition, not a copy of it -------------

(def boot
  (test/start! {:plugins [:void/http :void/obs :void/mcp :void/mcp-http :void/mcp-obs]
                :only [:http/kernel :obs/registry]
                :config (config {})}))

(def uris ((mcp/exposed) :resources))
(assert (index-of "void://metrics" uris) "the metrics resource is published")

(def read (mcp/handle @{:id 1 :method "resources/read"
                        :params @{:uri "void://metrics"}}))
(def text (get-in read [:result :contents 0 :text]))
(assert (string/find "void_" text) "and it is this process's own exposition")
(assert (string/has-prefix? "text/plain" (get-in read [:result :contents 0 :mimeType]))
        "in the media type a Prometheus reader expects")

(test/stop! boot)

# -- nothing here is a store a second replica would have to see ----------
#
# The HTTP transport issues no session id and holds no stream between
# requests, so a fleet composition has nothing to fix: ADR-0030's
# survey passes without void/mcp declaring anything (ADR-0031 §5).

(def fleet
  (test/start! {:plugins [:void/http :void/mcp :void/mcp-http]
                :only [:http/kernel]
                # sessions off: void/http's cookie sessions are a store
                # of their own and ADR-0030 has already asked them the
                # question — this composition is here to show that
                # void/mcp adds no second one
                :config (config {:deploy {:shape :fleet}
                                 :mcp-http {:token "t"}
                                 :http {:port 0 :session {:enabled false}}})}))
(assert (= :ready (fleet :phase)) "an MCP server starts under [:deploy :shape] :fleet")
(test/stop! fleet)

(print "plugin-test ok")
