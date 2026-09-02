# The wave-1 example is also its smoke test (ROADMAP, сквозные
# работы), and it tests the way void apps are meant to be tested
# (ADR-0017): kernel-only start — no port — with test/inject driving
# the full production stack: routing, lifecycle stages, middleware,
# schema validation, rendering, wire serialization. The access-log
# lands through void/core/log on the :on-response stage — the same
# record a socket request would produce (wave-1 exit criterion 5).

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http :as http)
(import main)

# capture the structured log records the app emits
(def records @[])
(log/set-sinks! [(fn [rec] (array/push records (freeze rec)))])

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{} :cli {:http {:port 0}
                                  :dev {:netrepl {:enabled false}
                                        :watch {:enabled false}}}}}))

# the composition is valid before anything starts
(assert ((plugin/dry-run opts) :ok) "dry-run passes")

(test/with-http [c opts]

  # log sinks survive the boot's log configuration
  (log/set-sinks! [(fn [rec] (array/push records (freeze rec)))])

  # kernel-only: the app is fully wired, no socket exists
  (assert (nil? (get-in (c :boot) [:system :instances :http/server]))
          "test/with-http starts :only [:http/kernel]")

  # -- GET /: server-rendered page with the schema-driven form -----------
  (def page (test/inject c {:uri "/"}))
  (assert (= 200 (page :status)))
  (def body (test/text page))
  (assert (string/has-prefix? "<!DOCTYPE html>" body) "full page renders")
  (assert (string/find `action="/entries"` body) "the form targets POST /entries")
  (assert (string/find "hx-post" body) "the form is htmx-enhanced")
  (assert (string/find `name="message"` body) "schema fields become controls")
  (assert (string/has-prefix? "HTTP/1.1 200" (page :raw))
          ":raw carries the exact wire bytes")

  # the access-log record fired on :on-response through void/core/log
  (def access (filter |(= "void.http.access" ($ :ns)) records))
  (assert (= 1 (length access)) "one access-log record per request")
  (assert (= "/" ((access 0) :path)))
  (assert (= 200 ((access 0) :status)))
  (assert (string? ((access 0) :request-id))
          "the request-id middleware bound the log context")

  # -- invalid POST: schema errors re-render the same form ---------------
  (def bad (test/inject c {:uri "/entries"
                           :form {:name "" :message ""}}))
  (assert (string/find "field-errors" (test/text bad))
          "schema/check errors land next to their fields")

  # -- valid POST as htmx request: fragment without layout ---------------
  (def good (test/inject c {:uri "/entries"
                            :headers {"hx-request" "true" "hx-request-type" "partial"}
                            :form {:name "ada" :message "first entry"}}))
  (assert (string/find "first entry" (test/text good)) "the entry is listed")
  (assert (not (string/find "<html" (test/text good)))
          ":void.htmx/partial answers htmx with the bare fragment")

  # -- explain-route: every value's origin, middleware chain -------------
  (def ex (http/explain-route "/entries" :post))
  (assert (= :entries/create (ex :name)))
  (assert (= :route (get-in ex [:layers :void.htmx/partial 0 :source]))
          "provenance names the layer that set the key")
  (assert (index-of :void.html/render (ex :middleware))
          "the resolved middleware chain is visible")
  (assert (string/find "middleware:" (ex :text))))

(log/set-sinks! nil)
(print "guestbook smoke-test ok")
