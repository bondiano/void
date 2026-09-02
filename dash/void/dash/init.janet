### void/dash — the dev dashboard as a projection (ROADMAP wave 7).
###
### Phoenix has LiveDashboard and Clojure has Portal; void's kernel
### already answers everything either of them shows — plugin/inspect,
### plugin/why, config/explain, hooks/handlers, deploy/survey,
### boot :system, plugin/health, routes-table, explain-route — as plain
### data, to a REPL, to Prometheus, to an agent over MCP and to the
### CLI. This package is the fourth projection of the same values:
### HTML, under `[:dash :prefix]` (default "/dash").
###
### Four decisions worth knowing before reading further:
###
### **The dashboard is a reader.** Every page renders a value that
### existed before the page did. What the package adds of its own is
### bounded memory — three rings: the last log records (the one hole
### the kernel audit found), a fixed history of samples for the
### sparklines, and the tap buffer — plus one sampler fiber.
###
### **It degrades by composition, not by configuration.** The edges
### are core, http, html, htmx and (as a module, the void/storage/sign
### pose) datastar. void/obs, void/pressure and the rest are *read
### through the boot value* — a component's own :health, by key — so a
### composition without them gets a page that names the plugin that
### would fill the section, in the same voice a boot error speaks.
###
### **The gate is shut everywhere but :dev.** The netrepl logic: a dev
### process already hands a REPL to whoever can reach it. Every other
### profile refuses every route until `[:dash :access]` names a
### predicate, with the refusal naming the key (./mount). Pages are
### read-only; the one action — runtime log levels — sits separately
### behind `[:dash :allow-actions]` (true in :dev).
###
### **Live is an experiment the fallback does not wait for.** With
### void/datastar in the composition the overview and the log page
### ride a morph-stream — the page re-renders whole, Datastar morphs
### the delta (ADR-0037's idiom, on its first real consumer). Without
### it, htmx polls every 5 seconds, which is the same data a moment
### later.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/core/system :as system)
(import ./context :as ctx)
(import ./history :as history)
(import ./live :as live)
(import ./logs :as logs)
(import ./mount :as mount)
(import ./pages :as pages)
(import ./tap :as tapmod)
(import ./view :as view)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.dash")

# -- the public tap ------------------------------------------------------

(def tap*
  "See void/dash/tap: (dash/tap* value &opt where) — put a value in
  the tap ring and return it."
  tapmod/tap*)

(defmacro tap
  ``tap*, with the call site written down — the REPL and in-code
  helper the Tap page reads:

      (import void/dash :as dash)
      (dash/tap (order-totals basket))``
  [x]
  (def [l _] (or (tuple/sourcemap (dyn :macro-form)) [nil nil]))
  (def where (string (or (dyn :current-file) "?")
                     (if (and l (pos? l)) (string ":" l) "")))
  ~(,tapmod/tap* ,x ,where))

# -- extension points ----------------------------------------------------

(plugin/defextension-point :void.dash/tile
  :doc "Tiles on the dashboard overview: {:name :orders/backlog :label \"Backlog\"? :render (fn [] hiccup)}. A tile that throws renders its error instead of taking the page down"
  :schema {:name :keyword
           :render :function
           :label [:optional :string]
           :doc [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate dash tile %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:dash] config slice."
  {:prefix [:optional :string]
   :title [:optional :string]
   :access [:optional :function]
   :allow-actions [:optional :boolean]
   :log-buffer [:optional [:int {:min 1}]]
   :tap-buffer [:optional [:int {:min 1}]]
   :history [:optional {:interval [:optional [:number {:min 0.05}]]
                        :samples [:optional [:int {:min 2}]]}]
   :htmx-src [:optional :string]
   :htmx-integrity [:optional :string]
   :route-meta [:optional :dictionary]})

(def defaults
  ``Defaults of the [:dash] slice.

  `:access` is deliberately absent — its absence is what keeps the
  gate shut outside :dev, and a default here would be the
  vulnerability the construction exists to avoid. `:allow-actions` is
  absent too: unset, it follows the profile (true in :dev, false
  everywhere else).``
  {:prefix "/dash"
   :title "Dash"
   :log-buffer 500
   :tap-buffer 100
   :history {:interval 5 :samples 360}})

# -- the context ---------------------------------------------------------

(defn build-context
  "Assemble the dash context from a boot value: the [:dash] slice, the
  gate posture for this profile, the tile contributions, and the three
  rings sized to their config. Normally called by the :before-start
  hook."
  [boot]
  (def cfg (merge defaults (or (get-in boot [:config :values :dash]) {})))
  (def profile (boot :profile))
  (def open? (= :dev profile))
  (def hist (merge (defaults :history) (or (cfg :history) {})))
  (logs/configure! (cfg :log-buffer))
  (tapmod/configure! (cfg :tap-buffer))
  (history/configure! hist)
  (set ctx/current
       @{:boot boot
         :config cfg
         :prefix (cfg :prefix)
         :title (cfg :title)
         :open? open?
         :access (cfg :access)
         :allow-actions? (if (nil? (cfg :allow-actions)) open? (true? (cfg :allow-actions)))
         :started-at (os/clock :monotonic)
         :history hist
         :datastar? (truthy? (get-in boot [:system :components :datastar/registry]))
         :tiles (or (get-in boot [:extensions :void.dash/tile :resolved]) [])
         :route-meta (get cfg :route-meta {})
         :htmx-src (cfg :htmx-src)
         :htmx-integrity (cfg :htmx-integrity)
         :sample-sources (fn dash-sources [] (pages/sample-sources boot))
         :assets (view/asset-bundle)})
  (log/info "dash ready" :ns log-ns
            :prefix (cfg :prefix)
            :open (or open? (truthy? (cfg :access)))
            :actions (ctx/setting :allow-actions?)
            :datastar (ctx/setting :datastar?))
  ctx/current)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 420
   :name :dash/build-context
   :doc "Resolve the dash config, gate posture and ring sizes before the route table is built"
   :fn (fn build! [boot] (build-context boot))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 150
   :name :dash/warn-when-shut
   :doc "Say once, at start, that the dashboard is mounted and refusing everybody"
   :fn (fn warn [_boot]
         (when (and ctx/current
                    (not (ctx/current :open?))
                    (nil? (ctx/current :access)))
           (log/warn (string "the dashboard is mounted and refuses every request: "
                             "[:dash :access] names no predicate")
                     :ns log-ns :prefix (ctx/current :prefix))))})

# -- the log ring --------------------------------------------------------

(plugin/contribute! :void.core/log-sink
  {:name :void.dash/ring
   :doc "The last [:dash :log-buffer] records in a ring, feeding the Logs page and its SSE tail — the buffer log/emit never had"
   :fn logs/sink})

# -- the component -------------------------------------------------------

(def state-component
  (system/component :dash/state
    :doc "The dashboard's one moving part: the history sampler fiber
    (loop lag measured around its own sleep; RSS and connections read
    through the component-health seam when their components are in the
    composition), and the lifecycle of the log-tail subscriptions.
    Depends on :http/server so a drain closes the tails before the
    listener goes — stopping runs in reverse dependency order."
    :deps [:http/server]
    :start
    (fn start [_ _]
      (def c (ctx/context))
      (def running @{})
      (def fib (ev/go (history/sampler (get-in c [:history :interval] 5)
                                       (c :sample-sources)
                                       running
                                       (fn poke [] (live/poke! live/overview-room)))))
      @{:running running :fiber fib})
    :stop
    (fn stop [inst]
      (put (inst :running) :stop true)   # honored within 0.1 s, no cancel
      (logs/close-subscribers!))
    :health
    (fn health [inst]
      {:status :up
       :samples (history/held)
       :log-records (logs/held)
       :tails (length logs/subscribers)})))

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/dash
  :doc "The dev dashboard as a fourth projection of what the process already answers a REPL with (Phoenix LiveDashboard + Portal, at void's scale): overview with health tiles and sparklines, the component graph with plugin/why, plugins and extension points with attribution, config with per-value provenance (secrets are boxes and print as their reference), the live route table with explain-route, the deploy survey, a log ring with filters, runtime per-namespace levels and an SSE live tail, and a tap inspector for values sent from code or the netrepl. Own routes under [:dash :prefix], open in :dev and shut elsewhere until [:dash :access] names a predicate; when void/datastar is composed the overview and logs ride a morph-stream, otherwise htmx polls."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"
             :void/html ">=0.0.1" :void/htmx ">=0.0.1"}
  :config-key :dash
  :config-schema Config
  :config-defaults defaults
  :components [state-component]
  :contributes
  {:void.http/route-source
   [{:name :void/dash
     # a function, not a value: the prefix and the gate live in the
     # context built at :before-start, after this manifest froze
     :routes (fn dash-routes [_boot] (mount/routes))}]})
