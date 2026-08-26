# A real prefork application for the e2e test: void/run! + void/http
# with :workers 2 on a fixed port (VOID_TEST_PORT). The master process
# supervises; each worker re-execs this same script (VOID_HTTP_WORKER
# set) and binds the shared port via SO_REUSEPORT. SIGTERM drains
# everything through the normal lifecycle. Run with cwd = http/.

(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))
(add-tree (string (os/cwd) "/../core"))
(add-tree (os/cwd))

(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(require "void/http/init")

(defn worker-id [req]
  (ring/text 200 (string "worker=" (or (os/getenv "VOID_HTTP_WORKER") "master"))))

(def app
  (plugin/manifest 'test/prefork-app
    :version "0.1.0"
    :contributes
    {:void.http/route-source
     [{:name :test/prefork-app
       :routes (router/routes {}
                 (router/GET "/worker" 'worker-id {:name :worker}))
       :env (router/env-ref (curenv))}]}))

(void/run!
  {:plugins [:void/http app]
   :profile :test
   :config {:env @{}
            :cli {:http {:port (scan-number (os/getenv "VOID_TEST_PORT"))
                         :workers 2
                         :drain-timeout 2}}}})
