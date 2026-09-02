### The M1 pages, through inject (ADR-0017) — and the gate.
###
### Claims. In :dev the dashboard is open (the netrepl logic) and every
### page is a projection: the overview says which sections have no
### source in this composition and which plugin would add one; the
### components page is boot :system; plugin/why, plugin/inspect,
### config/explain (with a secret that stays a box), the route table
### with per-key provenance, and the deploy survey each render from the
### value the REPL already answers. Outside :dev every route refuses
### with the phrase naming [:dash :access], a predicate opens it, and a
### predicate's refusal is a refusal.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/test :as test)

(log/set-level! nil :error)

(def plugins
  ["void/http/init" "void/html/init" "void/htmx/init" "void/dash/init"])

(defn- start [profile &opt dash-cfg]
  (test/start! {:plugins plugins
                :profile profile
                :config {:env @{"APP_TOKEN" "s3cr3t-value"}
                         :cli {:http {:port 0}
                               :app {:token {:secret "APP_TOKEN"}}
                               :dash (or dash-cfg {})}}
                :only [:http/kernel]}))

# -- :dev — open, and every page answers ---------------------------------

(def boot (start :dev))

(defer (test/stop! boot)
  (def c (test/client boot))
  (defn GET [uri] (test/inject c {:uri uri}))

  (def overview (GET "/dash"))
  (assert (= 200 (overview :status)) (string "overview: " (overview :status)))
  (def page (test/text overview))
  (assert (string/find "Overview" page))
  (assert (string/find ":void/obs" page)
          "the runtime card names the plugin that would fill it")
  (assert (string/find ":void/pressure" page)
          "so does the pressure card")
  (assert (string/find "plugin/health" page)
          "the health tiles say what fold they are")
  (assert (string/find "profile dev" page) "the process card knows its profile")

  # the poll fragment on the same URL
  (def frag (test/inject c {:uri "/dash"
                            :headers {"hx-request" "true" "hx-request-type" "partial"}}))
  (assert (= 200 (frag :status)))
  (assert (not (string/find "<html" (test/text frag)))
          "a partial htmx request gets the moving half and no frame")
  (assert (string/find `id="dash-overview"` (test/text frag)))

  # components: boot :system in topological order, why on click
  (def comps (GET "/dash/components"))
  (assert (= 200 (comps :status)))
  (assert (string/find "http/kernel" (test/text comps)))

  (def why (GET "/dash/why?key=http/kernel"))
  (assert (= 200 (why :status)))
  (assert (string/find "brought by plugin" (test/text why)))
  (assert (string/find "void/http" (test/text why)))

  (def why-missing (GET "/dash/why?key=no/such"))
  (assert (string/find "unknown component" (test/text why-missing))
          "an unknown key answers with plugin/why's own refusal, not a crash")

  # plugins and points
  (def plugs (GET "/dash/plugins"))
  (assert (= 200 (plugs :status)))
  (assert (string/find "void/dash" (test/text plugs)))
  (assert (string/find ":void.dash/tile" (test/text plugs)))

  (def point (GET "/dash/point?name=:void.core/log-sink"))
  (assert (= 200 (point :status)))
  (assert (string/find ":void.dash/ring" (test/text point))
          "the point detail shows the contribution with its plugin")

  # config: provenance per value, the secret stays a box
  (def cfg (GET "/dash/config"))
  (assert (= 200 (cfg :status)))
  (def cfg-page (test/text cfg))
  (assert (string/find "defaults of plugin" cfg-page)
          "a defaulted value says which plugin's defaults set it")
  (assert (string/find "APP_TOKEN" cfg-page)
          "the secret shows as its reference")
  (assert (not (string/find "s3cr3t-value" cfg-page))
          "and never as its value — safe by construction")

  # routes: the live table, provenance on click
  (def routes (GET "/dash/routes"))
  (assert (= 200 (routes :status)))
  (assert (string/find "dash/overview" (test/text routes)))

  (def route (GET "/dash/route?name=dash/config"))
  (assert (= 200 (route :status)))
  (assert (string/find ":name" (test/text route))
          "explain lists every metadata key with its origin")

  # deploy: shape and survey
  (def dep (GET "/dash/deploy"))
  (assert (= 200 (dep :status)))
  (assert (string/find "shape" (test/text dep)))

  # the stylesheet is served, fingerprinted, from under the prefix
  (def sheet-href
    (let [at (string/find "/dash/-/assets/" page)]
      (assert at "the frame links the served sheet")
      (string/slice page at (string/find `"` page at))))
  (def sheet (GET sheet-href))
  (assert (= 200 (sheet :status)))
  (assert (string/find "dash-card" (test/text sheet)))

  # no datastar in this composition: the live stream says which plugin
  (def live (GET "/dash/live"))
  (assert (= 404 (live :status)))
  (assert (string/find ":void/datastar" (test/text live))))

# -- outside :dev the gate is shut ---------------------------------------

(def shut (start :test))
(defer (test/stop! shut)
  (def c (test/client shut))
  (def resp (test/inject c {:uri "/dash"}))
  (assert (= 403 (resp :status)) "no predicate, no page")
  (assert (string/find "[:dash :access]" (test/text resp))
          "and the refusal names the key that opens it")
  (assert (= 403 ((test/inject c {:uri "/dash/config"}) :status))
          "every route carries the same gate"))

# -- a predicate opens it, and its refusal is a refusal ------------------

(def gated (start :test {:access (fn [req] (= "op" (get-in req [:headers "x-operator"])))}))
(defer (test/stop! gated)
  (def c (test/client gated))
  (assert (= 403 ((test/inject c {:uri "/dash"}) :status)))
  (def ok (test/inject c {:uri "/dash" :headers {"x-operator" "op"}}))
  (assert (= 200 (ok :status)) "the predicate decides"))

(print "pages-test: ok")
