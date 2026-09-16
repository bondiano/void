### void/dash/text — the dashboard's own words, in one table.
###
### The same shape void/admin uses: every string a page puts in front of
### a person is a key here, `text/t` asks the bound catalog first, and
### this table is the fallback rather than a second copy of it. A
### composition with no void/i18n reads English; one with a dictionary
### reads whatever the dictionary says, and this package keeps no edge
### to that one.
###
### **What stays untranslated, on purpose.** dash prints the runtime's
### own vocabulary: component keys, extension-point names, plugin names,
### log levels, config paths, route patterns, the `:status` words of a
### health fold. Those are identifiers, not words — an operator matches
### them against `void routes`, a log line and a config file, and a
### translated identifier is one that no longer matches anything. Column
### headers that *name* such a thing (`component`, `plugin`, `point`,
### `level`) are the same identifiers in a header cell, so they stay
### too; the sentences around them do not.

(import void/core/text)

(def en
  "The dashboard's words."
  {# the frame
   :void.dash/overview "Overview"
   :void.dash/components "Components"
   :void.dash/plugins "Plugins"
   :void.dash/config "Config"
   :void.dash/routes "Routes"
   :void.dash/deploy "Deploy"
   :void.dash/logs "Logs"
   :void.dash/tap "Tap"

   # the vitals strip
   :void.dash/vital-process "Process"
   :void.dash/vital-runtime "Runtime"
   :void.dash/vital-http "HTTP"
   :void.dash/vital-pressure "Pressure"
   :void.dash/process-note "up · profile {profile} · shape {shape}"
   :void.dash/runtime-note "rss · loop lag p99 {p99} (max {max}){sampling}"
   :void.dash/sampler-off " · sampler off"
   :void.dash/lag-caption "loop lag, dash's own samples"
   :void.dash/http-note "open connections · port {port} · {status}"
   :void.dash/http-absent (string "the :http/server component is not running — a "
                                  "kernel-only boot (test/with-http) has no listener.")
   :void.dash/pressure-shedding "shedding"
   :void.dash/pressure-ok "ok"
   :void.dash/pressure-note "mode {mode} · episodes {episodes} · shed {shed}"

   # health
   :void.dash/health "Health"
   :void.dash/health-note " — plugin/health, the same fold GET /health and void/mcp answer with"
   :void.dash/at-a-glance "At a glance"

   # the table toolbar
   :void.dash/filter-label "Filter {what}"
   :void.dash/filter-placeholder "type to narrow…"
   :void.dash/rows "Rows"
   :void.dash/what-components "components"
   :void.dash/what-plugins "plugins"
   :void.dash/what-paths "paths"
   :void.dash/what-routes "routes"

   # components
   :void.dash/components-note (string "boot :system — the graph in topological order: every "
                                      "component after the ones it depends on.")
   :void.dash/why "why?"
   :void.dash/pick-component (string "Pick a component — plugin/why answers: who brought it, "
                                     "and who depends on it.")
   :void.dash/why-interface "interface {name}"
   :void.dash/why-providers "providers: {providers}"
   :void.dash/why-selected "selected: {selected}"
   :void.dash/why-only-one "the only one"
   :void.dash/why-brought-by "brought by plugin {plugin} · state {state}"
   :void.dash/why-provides "provides: {provides}"
   :void.dash/why-depends-on "depends on: {deps}"
   :void.dash/why-nothing "nothing"
   :void.dash/why-no-dependents "nothing depends on it"
   :void.dash/why-dependents "depended on by:"
   :void.dash/why-via " via {via}"

   # plugins and extension points
   :void.dash/extension-points "Extension points"
   :void.dash/open "open"
   :void.dash/yes "yes"
   :void.dash/no "no"
   :void.dash/pick-point (string "Pick a point — its contributions with the plugin each came "
                                 "from, and the folded value the owner reads.")
   :void.dash/unknown-point "unknown extension point {name}"
   :void.dash/no-contributions "No contributions."
   :void.dash/resolved "resolved: "

   # config
   :void.dash/config-note (string "profile {profile} · layers: {layers} (later wins) · every "
                                  "value with the layer that set it — config/explain. Secrets "
                                  "are boxes and print as their reference: safe by construction.")
   :void.dash/overrides " (overrides: {shadowed})"

   # routes
   :void.dash/routes-note (string "The live route table — what `void routes` prints; opening a "
                                  "line is explain-route: every metadata key with the layer "
                                  "that set it.")
   :void.dash/pick-route "Pick a route."
   :void.dash/no-route-named "no route named {name}"
   :void.dash/route-note "source {source} · middleware: {middleware}"
   :void.dash/route-no-middleware "none"

   # deploy
   :void.dash/deploy-note (string "shape {shape} ({reason}) — deploy/survey: every store this "
                                  "composition keeps, and whether a second replica would see it.")
   :void.dash/no-stores "Stores: none — nothing this composition keeps outlives a request."
   :void.dash/store-shared "shared"
   :void.dash/store-by-design "by design"
   :void.dash/store-unknown "no answer"
   :void.dash/store-per-process "per-process"

   # logs
   :void.dash/level-at-least "Level ≥"
   :void.dash/any "any"
   :void.dash/namespace-contains "Namespace contains"
   :void.dash/filter "Filter"
   :void.dash/log-levels "Log levels"
   :void.dash/namespace-root "Namespace (empty = root)"
   :void.dash/level "Level"
   :void.dash/set "Set"
   :void.dash/actions-off (string "Changing levels is off: [:dash :allow-actions] is not true "
                                  "in this profile — the pages stay read-only until the config "
                                  "says otherwise.")
   :void.dash/logs-held {:one "{shown} of {total} held record (ring of {capacity}) · live tail: "
                         :other "{shown} of {total} held records (ring of {capacity}) · live tail: "}
   :void.dash/sse-stream "SSE stream"
   :void.dash/dropped " · dropped by async sinks: {dropped}"
   :void.dash/no-record "No record matches."

   # tap
   :void.dash/tap-note (string "(dash/tap value) from code or the netrepl puts a value here — "
                               "a ring of {capacity}, newest first. {held} held.")
   :void.dash/tap-empty (string "Nothing tapped yet. From the REPL: (import void/dash :as dash) "
                                "(dash/tap {{:hello :world})")
   :void.dash/tap-one "Tap #{id}"
   :void.dash/tap-gone (string "tap #{id} is no longer held — the ring keeps the last "
                               "{capacity} values, and this one was evicted.")
   :void.dash/tap-back-to-list "Back to the list"
   :void.dash/tap-as-table "As a table"
   :void.dash/tap-tree "Tree"
   :void.dash/tap-copy-jdn "copy as JDN"
   :void.dash/tap-back "back"
   :void.dash/tap-whole "whole value"
   :void.dash/tap-evicted "this tap value was evicted"
   :void.dash/tap-bad-path "unreadable tree path"
   :void.dash/tap-branch-gone "this branch is gone"

   # a section with no source
   :void.dash/absent "{what} is not in this composition — composing {plugin} adds it."
   :void.dash/absent-obs "the RSS and loop-lag meter"
   :void.dash/absent-pressure "load shedding"})

(def t
  "One of the dashboard's words."
  (text/translator en))
