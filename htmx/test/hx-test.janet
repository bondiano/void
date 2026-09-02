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
(assert (deep= @{"mode" "once"} (json/decode ((hx/attrs :config {:mode "once"}) "hx-config")))
        "hx-config rides the same encoder — HCON reads JSON")

# htmx 4 swap styles
(assert (= "innerMorph" ((hx/attrs :swap :inner-morph) "hx-swap")))
(assert (= "outerMorph" ((hx/attrs :swap :outer-morph) "hx-swap")))
(assert (= "outerSync" ((hx/attrs :swap :outer-sync) "hx-swap")))
(assert (= "upsert" ((hx/attrs :swap :upsert) "hx-swap")))
(assert (= "beforeend" (hx/swap-style :append)) "position aliases resolve")
(assert (= "beforebegin" (hx/swap-style :before)))
(assert (= "afterbegin" (hx/swap-style :prepend)))
(assert (= "afterend" (hx/swap-style :after)))

# verb sugar
(assert (deep= (hx/attrs :get "/x" :target "#t") (hx/get* "/x" :target "#t")))
(assert (deep= @{"hx-delete" "/orders/7"} (hx/delete "/orders/7")))
(assert (deep= @{"hx-query" "/search"} (hx/query "/search"))
        "hx-query — the htmx 4 verb that sends its parameters in the body")

# attrs merge straight into hiccup
(def button (hiccup/render-string
              [:button (merge {:class "btn"} (hx/post "/orders" :swap :before-end))
               "add"]))
(each part [`class="btn"` `hx-post="/orders"` `hx-swap="beforeend"`]
  (assert (string/find part button) part))

# -- inherited -----------------------------------------------------------

(assert (deep= @{"hx-confirm:inherited" "Are you sure?"
                 "hx-target:inherited" "#main"}
               (hx/inherited :confirm "Are you sure?" :target "#main"))
        "htmx 4 inheritance is explicit — the suffix is on the name")
(assert (= "outerHTML" ((hx/inherited :swap :outer-html) "hx-swap:inherited"))
        "values translate under the suffix too")
(assert (= "sure?" ((hx/attrs :confirm:inherited "sure?") "hx-confirm:inherited"))
        "a colon-carrying keyword spells the same attribute by hand")

# -- status --------------------------------------------------------------

(def status-422 (hx/status 422 {:swap :inner-html :target "#errors"}))
(assert (deep= @{"swap" "innerHTML" "target" "#errors"}
               (json/decode (status-422 "hx-status:422"))))
(assert (deep= @{"hx-status:5xx" "swap:none"} (hx/status :5xx "swap:none"))
        "a wildcard code and a verbatim HCON spec")

# -- oob -----------------------------------------------------------------

(def oob-html (hiccup/render-string (hx/oob [:div {:id "cart"} 3])))
(each part [`hx-swap-oob="true"` `id="cart"` ">3</div>"]
  (assert (string/find part oob-html) part))
(assert (string/find `hx-swap-oob="outerHTML"`
                     (hiccup/render-string (hx/oob [:tr {:id "r"} "x"] :outer-html))))
(assert (= `<hr hx-swap-oob="true"/>` (hiccup/render-string (hx/oob [:hr]))))
(assert (not (first (protect (hx/oob "not an element")))))

# -- partial -------------------------------------------------------------

(assert (= `<hx-partial hx-target="#cart-count">3</hx-partial>`
           (hiccup/render-string (hx/partial "#cart-count" 3)))
        "a string spec is the target selector")
(assert (= `<hx-partial hx-target="#messages" hx-swap="beforeend"><li>new</li></hx-partial>`
           (hiccup/render-string
             (hx/partial {:target "#messages" :swap :before-end} [:li "new"])))
        "a dictionary spec carries the swap style")
(assert (not (first (protect (hx/partial {:swap :none} "x"))))
        "a partial without a target has nowhere to go")

# several regions from one response, main swap and all
(def multi (hiccup/render-string
             [[:li "gadget"]
              (hx/partial "#cart-count" 3)
              (hx/partial {:target "#flash" :swap :inner-html} [:p "added"])]))
(each part ["<li>gadget</li>"
            `<hx-partial hx-target="#cart-count">3</hx-partial>`
            `<hx-partial hx-target="#flash" hx-swap="innerHTML">`]
  (assert (string/find part multi) part))

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
(htmx/reswap resp :outer-morph)
(assert (= "outerMorph" (get-in resp [:headers "hx-reswap"])))
(htmx/reselect resp "#form")
(assert (= "#form" (get-in resp [:headers "hx-reselect"])))

# stop-polling: htmx 4 polls as long as the element is in the document,
# so the end of the poll is a swap that takes the element out
(def stopped (htmx/stop-polling))
(assert (= 200 (stopped :status)))
(assert (= "delete" (get-in stopped [:headers "hx-reswap"])))
(def replaced (htmx/stop-polling "<p>done</p>"))
(assert (= "outerHTML" (get-in replaced [:headers "hx-reswap"]))
        "content in the poll's place replaces the element instead")
(assert (= "<p>done</p>" (string (replaced :body))))

# -- request predicates --------------------------------------------------

(def hreq @{:headers @{"hx-request" "true"
                       "hx-request-type" "partial"
                       "hx-target" "div#list"
                       "hx-source" "button#refresh"
                       "hx-current-url" "http://x/orders"}})
(assert (htmx/request? hreq))
(assert (not (htmx/boosted? hreq)))
(assert (not (htmx/history-restore? hreq)))
(assert (= "partial" (htmx/request-type hreq)))
(assert (htmx/partial-request? hreq))
(assert (not (htmx/full-request? hreq)))
(assert (= "div#list" (htmx/target hreq)))
(assert (= "button#refresh" (htmx/source hreq)))
(assert (= "list" (htmx/target-id hreq)) "htmx 4 names elements tag#id")
(assert (= "refresh" (htmx/source-id hreq)))
(assert (= "http://x/orders" (htmx/current-url hreq)))

(assert (nil? (htmx/element-id "button")) "an element with no id has none to give")
(assert (= "a b" (htmx/element-id "div#a%20b")) "the id arrives percent-encoded")
(assert (nil? (htmx/element-id nil)))

(def boosted @{:headers @{"hx-request" "true"
                          "hx-request-type" "full"
                          "hx-boosted" "true"
                          "hx-target" "body"}})
(assert (htmx/boosted? boosted))
(assert (htmx/full-request? boosted))
(assert (not (htmx/partial-request? boosted))
        "a boosted navigation swaps the body — it wants the whole page")
(assert (nil? (htmx/target-id boosted)))

(assert (not (htmx/request? @{:headers @{}})))
(assert (nil? (htmx/request-type @{:headers @{}})))
(assert (not (htmx/partial-request? @{:headers @{}})))

# -- header injection dies at the wire, htmx builders included -----------
#
# redirect, push-url, retarget and the rest put their argument straight
# into a response header; the wire writer refuses CR, LF and NUL, so a
# user-supplied URL cannot split the response on its way out.

(import void/http/wire :as wire)

(def evil (htmx/redirect (ring/response 200) "/a\r\nSet-Cookie: admin=1"))
(def [wok werr] (protect (wire/write-head @"" 200 (evil :headers))))
(assert (not wok) "an hx-redirect carrying CRLF never reaches the wire")
(assert (= "hx-redirect" (get werr :header)) "and the refusal names the header")

(assert (string/find "hx-redirect: /safe\r\n"
                     (string (wire/write-head @"" 200
                                              ((htmx/redirect (ring/response 200) "/safe")
                                               :headers))))
        "an honest redirect still renders")

(print "hx-test: ok")
