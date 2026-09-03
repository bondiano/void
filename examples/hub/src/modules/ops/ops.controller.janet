### ops/controller — the front door.
###
### **The jobs dashboard is the main screen.** A hub is not a site with
### a back office bolted on: receiving is a machine talking to a
### machine, and everything a *person* does here is operations. So the
### guestbook `void new` wrote is gone, and the question this
### application is asked at three in the morning — "did it go out" — is
### a question about the queue.
###
### Nothing was written to make 6.3's dashboard the front door:
### `void/admin-jobs` contributes the page, `void/http` reverse-routes
### its name, and this is the one line that follows. The target is
### reverse-routed rather than written out because `[:admin :prefix]` is
### config, and a string here would be a second place to change it
###  (every action is a real route, so every route has a name).
(import void/http)
(import void/http/ring :as ring)
(import void/http/router :as router)

(defn home
  "GET / — the queue."
  [_req]
  (ring/redirect (http/url-for :admin.page/jobs)))

(router/defroutes :hub/ops-routes
  (GET "/" home {:name :hub/home :void.auth/access :public}))
