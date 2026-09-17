# Handler fixtures for the router test-suite: referenced by qualified
# symbol 'test-support.fixtures.handlers/<name> to exercise late
# binding through the module environment.

(defn hello
  {:params [:any] :ret HttpResponse}
  "A route handler with nothing to say but its own name — bound by
  qualified symbol from the router test-suite to exercise late
  binding."
  [req]
  {:status 200 :body "hello"})

(defn echo-id
  {:params [HttpRequest] :ret HttpResponse}
  "Reflects the router's :id param back as the body, so a test can
  check a bound-by-symbol handler actually receives what the router
  extracted."
  [req]
  {:status 200 :body (get-in req [:params :id])})
