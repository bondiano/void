# The hot-reload rebuild path (wave-1 exit criterion 1): the dev
# watcher fires :void.dev/reloaded after a dofile reload, and
# void/http's hook contribution rebuilds the route table from the
# *live* manifest registry — a reloaded app module re-runs defplugin,
# which re-registers its manifest, so new routes and edited
# patterns/metadata go live without a restart. This test drives that
# machinery directly: re-register a grown manifest, fire the hook the
# way watch/notify-reloaded! does, watch the table change.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/hooks :as hooks)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)

(defn alpha [req] (ring/text 200 "alpha"))
(defn beta [req] (ring/text 200 "beta"))

(defn- app-manifest [routes]
  (plugin/manifest 'test/reload-app
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/reload-app
                               :routes routes
                               :env (router/env-ref (curenv))}]}))

(def v1
  (app-manifest
    (router/routes {}
      (router/GET "/alpha" 'alpha {:name :alpha}))))

(def boot
  (plugin/start!
    {:plugins ["void/http/init" v1]
     :profile :test
     :config {:env @{} :cli {:http {:port 0}}}}))

(defer (plugin/shutdown! boot 3)

  (assert (= 200 ((http/with-request {:uri "/alpha"}) :status)))
  (assert (= 404 ((http/with-request {:uri "/beta"}) :status))
          "route /beta does not exist yet")

  # a reloaded module re-runs defplugin -> the registry gets the grown
  # manifest (same name), while the boot value still holds the old one
  (plugin/register-manifest!
    (app-manifest
      (router/routes {:void.http/timeout 30}
        (router/GET "/alpha" 'alpha {:name :alpha})
        (router/GET "/beta" 'beta {:name :beta}))))

  # nothing changes until the watcher's hook fires
  (assert (= 404 ((http/with-request {:uri "/beta"}) :status)))

  # ... which is exactly what watch/notify-reloaded! does after a reload
  (def errs (hooks/run-protected! (boot :hooks) :void.dev/reloaded
                                  boot @{:reloaded @["app.janet"]}))
  (assert (empty? errs) (string/join errs "; "))

  (assert (= 200 ((http/with-request {:uri "/beta"}) :status))
          "the new route went live")
  (assert (= "beta" (string ((http/with-request {:uri "/beta"}) :body))))
  (assert (= 30 (get-in (http/explain-route "/alpha") [:meta :void.http/timeout]))
          "edited global metadata went live too")

  # an empty reload report is a no-op for the hook
  (def table-before (http/routes-table))
  (hooks/run-protected! (boot :hooks) :void.dev/reloaded boot @{:reloaded @[]})
  (assert (= table-before (http/routes-table)) "no reloaded files, no swap")

  # a broken edit reports instead of tearing the watcher down: the
  # rebuild throws inside the hook, run-protected! collects it
  (plugin/register-manifest!
    (app-manifest
      (router/routes {}
        (router/GET "/alpha" 'alpha {:name :alpha})
        (router/GET "/beta" 'beta {:name :alpha}))))    # duplicate name
  (def errs2 (hooks/run-protected! (boot :hooks) :void.dev/reloaded
                                   boot @{:reloaded @["app.janet"]}))
  (assert (not (empty? errs2)) "a broken table lands in the error report")
  (assert (= 200 ((http/with-request {:uri "/beta"}) :status))
          "the previous table keeps serving"))

(print "reload-test: ok")
