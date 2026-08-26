(import ../test-support/paths)
(import spork/json)
(import void/htmx/hx :as hx)
(import void/html/hiccup :as hiccup)
(import void/http/ring :as ring)
(import void/htmx/init :as htmx)

# -- attrs ---------------------------------------------------------------

(assert (deep= @{"hx-get" "/orders" "hx-target" "#list" "hx-swap" "outerHTML"}
               (hx/attrs :get "/orders" :target "#list" :swap :outer-html)))

(assert (deep= @{"hx-boost" "true"} (hx/attrs :boost true)))
(assert (deep= @{"hx-get" "/x"} (hx/attrs :get "/x" :target nil))
        "nil drops the attribute")
(assert (deep= @{"hx-on:click" "alert(1)"} (hx/attrs "hx-on:click" "alert(1)"))
        "string keys pass through for hx-on:*")
(assert (= "outerHTML swap:1s" ((hx/attrs :swap "outerHTML swap:1s") "hx-swap"))
        "string swap values stay verbatim")
(assert (not (first (protect (hx/attrs :swap :sideways)))))

(def vals-attrs (hx/attrs :post "/vote" :vals {:id 7}))
(assert (deep= @{"id" 7} (json/decode (vals-attrs "hx-vals")))
        "dictionaries JSON-encode")

# verb sugar
(assert (deep= (hx/attrs :get "/x" :target "#t") (hx/get* "/x" :target "#t")))
(assert (deep= @{"hx-delete" "/orders/7"} (hx/delete "/orders/7")))

# attrs merge straight into hiccup
(def button (hiccup/render-string
              [:button (merge {:class "btn"} (hx/post "/orders" :swap :before-end))
               "add"]))
(each part [`class="btn"` `hx-post="/orders"` `hx-swap="beforeend"`]
  (assert (string/find part button) part))

# -- oob -----------------------------------------------------------------

(def oob-html (hiccup/render-string (hx/oob [:div {:id "cart"} 3])))
(each part [`hx-swap-oob="true"` `id="cart"` ">3</div>"]
  (assert (string/find part oob-html) part))
(assert (string/find `hx-swap-oob="outerHTML"`
                     (hiccup/render-string (hx/oob [:tr {:id "r"} "x"] :outer-html))))
(assert (= `<hr hx-swap-oob="true"/>` (hiccup/render-string (hx/oob [:hr]))))
(assert (not (first (protect (hx/oob "not an element")))))

# -- response header helpers ---------------------------------------------

(def resp (ring/response 200 ""))
(htmx/trigger resp :order-created)
(assert (= "order-created" (get-in resp [:headers "hx-trigger"])))

(htmx/trigger resp "a" :b)
(assert (= "a, b" (get-in resp [:headers "hx-trigger"])) "plain events comma-join")

(htmx/trigger resp {:show-toast {:level "info"}} :plain)
(def decoded (json/decode (get-in resp [:headers "hx-trigger"])))
(assert (deep= @{"level" "info"} (decoded "show-toast")))
(assert (deep= @{} (decoded "plain")) "payload-less events ride along in JSON form")

(htmx/trigger-after-swap resp :done)
(assert (= "done" (get-in resp [:headers "hx-trigger-after-swap"])))
(assert (not (first (protect (htmx/trigger resp)))))

(htmx/redirect resp "/orders")
(assert (= "/orders" (get-in resp [:headers "hx-redirect"])))
(htmx/location resp {:path "/orders" :target "#main"})
(assert (deep= @{"path" "/orders" "target" "#main"}
               (json/decode (get-in resp [:headers "hx-location"]))))
(htmx/refresh resp)
(assert (= "true" (get-in resp [:headers "hx-refresh"])))
(htmx/push-url resp false)
(assert (= "false" (get-in resp [:headers "hx-push-url"])))
(htmx/replace-url resp "/orders?page=2")
(assert (= "/orders?page=2" (get-in resp [:headers "hx-replace-url"])))
(htmx/retarget resp "#errors")
(assert (= "#errors" (get-in resp [:headers "hx-retarget"])))
(htmx/reswap resp :after-end)
(assert (= "afterend" (get-in resp [:headers "hx-reswap"])))
(htmx/reselect resp "#form")
(assert (= "#form" (get-in resp [:headers "hx-reselect"])))
(assert (= 286 ((htmx/stop-polling) :status)))

# -- request predicates --------------------------------------------------

(def hreq @{:headers @{"hx-request" "true"
                       "hx-target" "list"
                       "hx-trigger" "refresh-btn"
                       "hx-trigger-name" "refresh"
                       "hx-prompt" "sure"
                       "hx-current-url" "http://x/orders"}})
(assert (htmx/request? hreq))
(assert (not (htmx/boosted? hreq)))
(assert (not (htmx/history-restore? hreq)))
(assert (= "list" (htmx/target hreq)))
(assert (= "refresh-btn" (htmx/trigger-id hreq)))
(assert (= "refresh" (htmx/trigger-name hreq)))
(assert (= "sure" (htmx/prompt hreq)))
(assert (= "http://x/orders" (htmx/current-url hreq)))
(assert (not (htmx/request? @{:headers @{}})))

(print "hx-test: ok")
