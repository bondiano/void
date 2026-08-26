# The wave-1 example is also its smoke test (ROADMAP, сквозные
# работы): boot the app exactly as `void dev` would — full plugin
# lifecycle, no socket games beyond an ephemeral port — and drive the
# guestbook loop through http/with-request: full page, invalid POST
# re-rendered with schema errors, valid POST as an htmx fragment,
# explain-route provenance.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/http :as http)
(import main)

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{} :cli {:http {:port 0}
                                  :dev {:netrepl {:enabled false}
                                        :watch {:enabled false}}}}}))

# the composition is valid before anything starts
(def report (plugin/dry-run opts))
(assert (report :ok) "dry-run passes")

(def boot (plugin/start! opts))
(defer (plugin/shutdown! boot 3)

  # -- GET /: server-rendered page with the schema-driven form -----------
  (def page (http/with-request {:uri "/"}))
  (assert (= 200 (page :status)))
  (def body (string (page :body)))
  (assert (string/has-prefix? "<!DOCTYPE html>" body) "full page renders")
  (assert (string/find `action="/entries"` body) "the form targets POST /entries")
  (assert (string/find "hx-post" body) "the form is htmx-enhanced")
  (assert (string/find `name="message"` body) "schema fields become controls")

  # -- invalid POST: schema errors re-render the same form ---------------
  (def bad (http/with-request
             {:method :post :uri "/entries"
              :headers {"content-type" "application/x-www-form-urlencoded"}
              :body "name=&message="}))
  (assert (string/find "field-errors" (string (bad :body)))
          "schema/check errors land next to their fields")

  # -- valid POST as htmx request: fragment without layout ---------------
  (def good (http/with-request
              {:method :post :uri "/entries"
               :headers {"content-type" "application/x-www-form-urlencoded"
                         "hx-request" "true"}
               :body "name=ada&message=first%20entry"}))
  (assert (string/find "first entry" (string (good :body))) "the entry is listed")
  (assert (not (string/find "<html" (string (good :body))))
          ":void.htmx/partial answers htmx with the bare fragment")

  # -- explain-route: every value's origin, middleware chain -------------
  (def ex (http/explain-route "/entries" :post))
  (assert (= :entries/create (ex :name)))
  (assert (= :route (get-in ex [:layers :void.htmx/partial 0 :source]))
          "provenance names the layer that set the key")
  (assert (index-of :void.html/render (ex :middleware))
          "the resolved middleware chain is visible")
  (assert (string/find "middleware:" (ex :text))))

(print "guestbook smoke-test ok")
