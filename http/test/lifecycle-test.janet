# Request-lifecycle stages: global hooks through the :void.http/hook
# point, route/group hooks through the :void.http/hooks metadata key
# (per-stage concat), short-circuit semantics, response-stage ordering
# around rendering-phase middleware, :on-error before renderers, and the
# out-of-chain :on-response / :on-timeout / :void.http/listening
# notifications on a real socket.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/hooks :as corehooks)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/wire :as wire)

(def calls @[])
(defn- mark [k] (array/push calls k))

# hooks as symbols prove late binding wiring; fns prove literals work
(defn global-on-request [req]
  (mark :global/on-request)
  nil)

(defn slow [req] (ev/sleep 10) (ring/text 200 "never"))

(defn show [req] (ring/text 200 "shown"))

(defn boom [req] (error "kaboom"))

(def app-routes
  (router/routes {}
    (router/group "/g" {:void.http/hooks {:pre-handler ['group-hook]}}
      (router/GET "/inner" 'show
        {:name :inner
         :void.http/hooks {:pre-handler ['route-hook]
                           :on-response ['route-on-response]}}))
    (router/GET "/gate" 'show
      {:name :gate
       :void.http/hooks {:on-request [(fn [req]
                                        (when (get-in req [:query "block"])
                                          (ring/text 403 "gated")))]}})
    (router/GET "/stagey" 'show
      {:name :stagey
       :void.http/hooks {:pre-serialization
                         [(fn [req resp]
                            (mark :pre-serialization)
                            (put resp :body (string (resp :body) "+pre-ser")))]
                         :on-send
                         [(fn [req resp]
                            (mark :on-send)
                            (put resp :body (string (resp :body) "+on-send")))]}})
    (router/GET "/boom" 'boom
      {:name :boom
       :void.http/hooks {:on-error [(fn [req err]
                                      (mark :on-error)
                                      (ring/text 599 (string "hooked: " err)))]}})
    (router/GET "/slow" 'slow
      {:name :slow
       :void.http/timeout 0.05
       :void.http/hooks {:on-timeout [(fn [req] (mark :on-timeout))]}})))

(defn group-hook [req] (mark :group/pre-handler) nil)
(defn route-hook [req] (mark :route/pre-handler) nil)
(defn route-on-response [req resp] (mark :route/on-response))

# a fake "rendering" middleware at the response phase proves the
# :pre-serialization slot (9800) runs inside it and :on-send (500)
# outside it
(def app-manifest
  (plugin/manifest 'test/lifecycle-app
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/lifecycle
                               :routes app-routes
                               :env (router/env-ref (curenv))}]
     :void.http/hook [{:stage :on-request :name :test/global-on-request
                       :fn 'global-on-request
                       :env (router/env-ref (curenv))}
                      {:stage :on-response :name :test/global-on-response
                       :fn (fn [req resp] (mark :global/on-response))}]
     :void.http/middleware [{:name :test/render
                             :phase 9000
                             :wrap (fn [h]
                                     (fn [req]
                                       (def resp (h req))
                                       (mark :render-mw)
                                       resp))}]}))

(def listened @[])
(def boot
  (plugin/start!
    {:plugins ["void/http/init" app-manifest
               (plugin/manifest 'test/listener
                 :version "0.1.0"
                 :contributes
                 {:void.core/hooks
                  [{:hook :void.http/listening
                    :name :test/heard
                    :fn (fn [b srv] (array/push listened (srv :port)))}
                   {:hook :void.http/route-added
                    :name :test/count-routes
                    :fn (fn [b entry] (mark [:route-added (entry :name)]))}]})]
     :profile :test
     :config {:env @{} :cli {:http {:port 0 :access-log false}}}}))

(defer (plugin/shutdown! boot 3)

  # route-added fired for every entry at build time
  (assert (index-of [:route-added :inner] calls) ":void.http/route-added ran")
  (assert (= 5 (length (filter |(and (indexed? $) (= :route-added (first $))) calls))))

  # :void.http/listening carried the bound server
  (assert (= 1 (length listened)) ":void.http/listening fired once")
  (assert (pos? (listened 0)))

  # -- in-chain order: global on-request, group then route pre-handler ---
  (array/clear calls)
  (def r1 (http/with-request {:uri "/g/inner"}))
  (assert (= 200 (r1 :status)))
  (assert (deep= @[:global/on-request :group/pre-handler :route/pre-handler
                   :render-mw]
                 calls)
          (string "in-chain hook order, got " (string/format "%j" calls)))

  # explain-route shows the stage wrappers in the chain
  (def ex (http/explain-route "/g/inner"))
  (assert (index-of :void.http.stage/on-request (ex :middleware)))
  (assert (index-of :void.http.stage/pre-handler (ex :middleware)))

  # -- short-circuit: a response from :on-request skips the handler ------
  (assert (= 403 ((http/with-request {:uri "/gate?block=1"}) :status)))
  (assert (= 200 ((http/with-request {:uri "/gate"}) :status)))

  # -- response stages sit around the rendering-phase middleware ---------
  (array/clear calls)
  (def r2 (http/with-request {:uri "/stagey"}))
  (assert (= "shown+pre-ser+on-send" (string (r2 :body))))
  (assert (deep= @[:global/on-request :pre-serialization :render-mw :on-send]
                 calls)
          (string ":pre-serialization inside, :on-send outside, got "
                  (string/format "%j" calls)))

  # -- :on-error runs before the renderers and may answer ----------------
  (array/clear calls)
  (def r3 (http/with-request {:uri "/boom"}))
  (assert (= 599 (r3 :status)) ":on-error hook response wins")
  (assert (string/find "kaboom" (string (r3 :body))))
  (assert (index-of :on-error calls))

  # -- the socket path: :on-response (global + route) and :on-timeout ----
  (def port (get-in boot [:system :instances :http/server :server :port]))
  (defn fetch [path]
    (def conn (net/connect "127.0.0.1" (string port)))
    (:write conn (string "GET " path " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
    (def buf @"")
    (while (net/read conn 4096 buf 2))
    (:close conn)
    buf)

  (array/clear calls)
  (fetch "/g/inner")
  (assert (index-of :global/on-response calls) "global :on-response after the write")
  (assert (index-of :route/on-response calls) "route :on-response after the write")

  (array/clear calls)
  (def slow-resp (fetch "/slow"))
  (assert (string/find "503" slow-resp))
  (assert (index-of :on-timeout calls) ":on-timeout on deadline cancellation"))

(print "lifecycle-test: ok")
