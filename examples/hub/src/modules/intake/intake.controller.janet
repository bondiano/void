### intake/controller — one route, and the four answers it can give.
###
### Unpack the request, call the service, pick the status. The order the
### service works in is the one thing this file preserves rather than
### decides: nothing is stored before the signature checks out, because
### storing first would make an unauthenticated stranger the author of
### this application's disk usage.
(import void/core/log :as log)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import spork/json)
(import ./intake.service :as intake)

(def log-ns "hub.intake")

(defn- accepted [status body]
  (ring/content-type (ring/response status (string (json/encode body)))
                     "application/json"))

(defn receive
  "POST /in/:source — the whole receiving end."
  [req]
  (def name (get-in req [:params :source]))
  (def cfg (intake/source name))
  (def body (or (req :body) ""))
  (cond
    (nil? cfg)
    (do (log/warn "delivery for an unknown source" :ns log-ns :source name)
        (accepted 404 {:error "unknown source"}))

    (not (intake/signature-ok? cfg body (get-in req [:headers "x-hub-signature-256"])))
    (do (log/warn "delivery with a signature that does not check out"
                  :ns log-ns :source name)
        (accepted 401 {:error "signature"}))

    (let [out (intake/receive! {:source name
                               :event (or (get-in req [:headers "x-github-event"]) "unknown")
                               :delivery-id (get-in req [:headers "x-github-delivery"])
                               :body body})]
      (case (out :status)
        :no-id (accepted 400 {:error "no delivery id"})
        :duplicate (accepted 202 {:status "duplicate" :delivery (out :delivery-id)})
        (accepted 202 {:status "received" :id (get-in out [:row :id])})))))

(router/defroutes :hub/intake-routes
  # No CSRF token and no session: the caller is a machine with a
  # signature, and this route is the one place in the application where
  # that is the whole of the authentication.
  #
  # And the one place that reads more than 64 KiB. GitHub caps a
  # delivery at 25 MiB; `:void.http/max-body` is `:restrict`, which
  # binds a route to the metadata layers above it — and there is no
  # layer above this one, because a source that declares no ceiling
  # declares none. `[:http :max-body]` is the value a route that says
  # nothing gets, so every other route in the application keeps 64 KiB
  # without a word (config/default.janet)
  (POST "/in/:source" receive {:name :intake/receive
                               :void.http/max-body 26214400}))
