# Handler fixtures for the router test-suite: referenced by qualified
# symbol 'test-support.fixtures.handlers/<name> to exercise late
# binding through the module environment.

(defn hello [req]
  {:status 200 :body "hello"})

(defn echo-id [req]
  {:status 200 :body (get-in req [:params :id])})
