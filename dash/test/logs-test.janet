### The log ring, the live tail, and the one action (M2).
###
### Claims. The contributed :void.core/log-sink keeps the last records
### and the Logs page shows them, filtered by level and namespace. The
### SSE tail delivers records as they are emitted — and releases its
### subscription when the consumer hangs up: the server cancels the
### body fiber, ring/sse forwards the cancel into the coro, and the
### defer runs (the A8 chain, the datastar stream-test's own fixture).
### Changing a namespace's level at runtime is allowed exactly when
### [:dash :allow-actions] says so, and the change itself is logged.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/wire :as wire)
(import void/dash/logs :as dlogs)

(log/set-level! nil :info)

(defn- start [&opt dash-cfg]
  (plugin/start!
    {:plugins ["void/http/init" "void/html/init" "void/htmx/init" "void/dash/init"]
     :profile :test
     :config {:env @{}
              :cli {:log {:level :info}
                    :http {:port 0}
                    :dash (merge {:access (fn [_] true)
                                  :log-buffer 50}
                                 (or dash-cfg {}))}}}))

(def boot (start {:allow-actions true}))

(defer (plugin/shutdown! boot 3)

  # -- the ring and the page ---------------------------------------------

  (log/info "the shipment left the dock" :ns "my-app.orders" :order 7)
  (log/warn "the shipment came back" :ns "my-app.orders")
  (log/info "unrelated hum" :ns "my-app.metrics")

  (def page (http/with-request {:uri "/dash/logs"}))
  (assert (= 200 (page :status)))
  (def body (string (page :body)))
  (assert (string/find "the shipment left the dock" body)
          "an emitted record is on the page")
  (assert (string/find "order=7" body) "with its key-values")

  (def filtered (http/with-request {:uri "/dash/logs?level=warn"}))
  (assert (string/find "came back" (string (filtered :body))))
  (assert (not (string/find "left the dock" (string (filtered :body))))
          "the level filter is a floor")

  (def by-ns (http/with-request {:uri "/dash/logs?ns=orders"}))
  (assert (not (string/find "unrelated hum" (string (by-ns :body))))
          "the namespace filter matches a substring")

  # -- the live tail ------------------------------------------------------

  (def tail (http/with-request {:uri "/dash/logs/tail"}))
  (assert (= "text/event-stream" (get-in tail [:headers "content-type"])))
  (def frames (tail :body))
  (assert (fiber? frames))
  (assert (string/find "void/dash log tail" (resume frames))
          "the tail greets, so a curl shows life before the first record")

  (log/info "a record for the tail" :ns "my-app.orders")
  (assert (string/find "a record for the tail" (resume frames))
          "an emitted record reaches the parked tail")

  # -- a hung-up consumer releases the subscription -----------------------

  (def before (length dlogs/subscribers))
  (def tail2 (http/with-request {:uri "/dash/logs/tail"}))
  (def body2 (tail2 :body))
  (var writes 0)
  (def dying @{:write (fn [_ _] (++ writes) (when (> writes 1) (error "broken pipe")))})
  (def outcome (ev/chan 1))
  (ev/go (fn broken-consumer []
           (ev/give outcome (protect (wire/write-body dying @"" body2)))))
  (ev/sleep 0.05)
  (assert (= (inc before) (length dlogs/subscribers))
          "the tail subscribed and is parked on its channel")
  (log/info "the record that meets the break" :ns "my-app.orders")
  (def [wrote _] (ev/take outcome))
  (assert (not wrote) "the broken pipe surfaced")
  (assert (not= :pending (fiber/status body2)) "the tail fiber is not left parked")
  (assert (= before (length dlogs/subscribers))
          "and its subscription is released — no leak")

  # -- the action ---------------------------------------------------------

  (assert (not (log/enabled? "my-app.orders" :debug)))
  (def set-resp (http/with-request {:method :post :uri "/dash/logs/level"
                                    :form {"ns" "my-app.orders" "level" "debug"}}))
  (assert (= 303 (set-resp :status)) (string "level set: " (set-resp :status)))
  (assert (log/enabled? "my-app.orders" :debug)
          "the namespace now logs at :debug — log/set-level! did the work")
  (assert (string/find "log level set from the dash"
                       (string ((http/with-request {:uri "/dash/logs?ns=void.dash"}) :body)))
          "and the change itself is a record in the ring")

  (def bad (http/with-request {:method :post :uri "/dash/logs/level"
                               :form {"ns" "x" "level" "loud"}}))
  (assert (= 422 (bad :status)) "an unknown level is a sentence, not a change"))

# -- read-only when actions are off --------------------------------------

(def ro (start {:allow-actions false}))
(defer (plugin/shutdown! ro 3)
  (def resp (http/with-request {:method :post :uri "/dash/logs/level"
                                :form {"ns" "x" "level" "debug"}}))
  (assert (= 403 (resp :status)))
  (assert (string/find "[:dash :allow-actions]" (string (resp :body)))
          "the refusal names the key")
  (assert (string/find "read-only" (string ((http/with-request {:uri "/dash/logs"}) :body)))
          "and the page says the form is off instead of drawing a dead one"))

(print "logs-test: ok")
