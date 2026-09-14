# The page-level helpers: flash messages that survive one redirect
# through the session, and the pager every list page reaches for.
# Flash is tested through the real session middleware — cookie, load,
# save — because "survives a redirect" is the whole of what it is.
(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/html :as html)
(import void/html/hiccup :as hiccup)
(import void/test :as test)

# -- pager: pagination as one call ----------------------------------------

(defn- render [x] (hiccup/render-string x))

(def p2 (render (html/pager {:page 2 :per-page 25 :total 130
                             :href (fn [p] (string "/orders?page=" p))})))
(each part [`<div class="vd-pager">` `<span class="vd-count">130 rows</span>`
            `href="/orders?page=1"` `← previous` `page 2 of 6`
            `href="/orders?page=3"` `next →`]
  (assert (string/find part p2) (string "pager renders " part)))

(def p1 (render (html/pager {:page 1 :per-page 25 :total 130
                             :href (fn [p] (string "/orders?page=" p))})))
(assert (nil? (string/find "previous" p1)) "the first page has no previous")
(assert (string/find "next →" p1) "and it has a next")

(def last* (render (html/pager {:page 6 :per-page 25 :total 130
                                :href (fn [p] (string "/orders?page=" p))})))
(assert (string/find "previous" last*) "the last page has a previous")
(assert (nil? (string/find "next →" last*)) "and no next")

(def empty* (render (html/pager {:page 1 :total 0 :href (fn [p] (string "/x?p=" p))})))
(assert (string/find "0 rows" empty*) "nothing counted is zero rows")
(assert (string/find "page 1 of 1" empty*) "and still one page, not zero")
(assert (nil? (string/find "previous" empty*)))

(def one (render (html/pager {:page 1 :total 1 :noun "order"
                              :href (fn [_] "/")})))
(assert (string/find "1 order<" one) ":noun, singular when the count is")
(assert (string/find "3 orders<" (render (html/pager {:page 1 :total 3 :noun "order"
                                                      :href (fn [_] "/")})))
        "and plural when it is not")

# a page under one reads as one; :attrs rides every link (an hx swap)
(def swapped (render (html/pager {:page 0 :total 60 :per-page 25
                                  :href (fn [_] "/orders")
                                  :attrs (fn [url] @{"hx-get" url})})))
(assert (string/find "page 1 of 3" swapped) "a page number under one is one")
(assert (string/find `href="/orders" hx-get="/orders"` swapped)
        ":attrs merges onto the link")

(assert (not (first (protect (html/pager {:page 1 :total 1}))))
        "a pager without :href has nowhere to point")

# -- the app: one route that flashes, one page that shows ----------------

(defn layout [content context]
  (def req (get context :request))
  (hiccup/html5
    [:head [:title "flash"]]
    [:body (when req (html/flash-view req)) [:main content]]))

(defn home [req]
  (html/page [:h1 "home"] {:layout layout}))

(defn save [req]
  (html/flash! req :ok "Saved.")
  (ring/redirect "/"))

(defn warn-two [req]
  (html/flash! req :warn "first")
  (html/flash! req :danger "second")
  (ring/redirect "/"))

(def app-routes
  (router/routes {}
    (router/GET "/" 'home {:name :home})
    (router/POST "/save" 'save {:name :save})
    (router/POST "/two" 'warn-two {:name :two})))

(def app
  (plugin/manifest 'test/flash-app
    :version "0.1.0"
    :requires {:void/html ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/flash-app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

# -- flash survives the redirect, and shows once -------------------------

(test/with-http [c {:plugins ["void/http/init" "void/html/init" app]
                    :config {:env @{}
                             :cli {:http {:port 0 :session {:enabled true}
                                          :access-log false}
                                  :log {:level :error}}}}]
  (def saved (test/inject c {:method :post :uri "/save"}))
  (assert (= 302 (saved :status)))

  (def page (test/inject c {:uri "/"}))
  (assert (string/find `class="vd-flash is-ok"` (test/text page))
          "the message the last page left is on this one")
  (assert (string/find "Saved." (test/text page)))

  (def again (test/inject c {:uri "/"}))
  (assert (nil? (string/find "vd-flash" (test/text again)))
          "and only once — the page that shows it takes it out of the session")

  # several messages queue in order, tone and all
  (test/inject c {:method :post :uri "/two"})
  (def two (test/inject c {:uri "/"}))
  (assert (string/find `class="vd-flash is-warn"` (test/text two)))
  (assert (string/find `class="vd-flash is-danger"` (test/text two)))
  (def wpos (string/find "first" (test/text two)))
  (def dpos (string/find "second" (test/text two)))
  (assert (and wpos dpos (< wpos dpos)) "in the order they were queued"))

# -- the readers, without a session --------------------------------------

(assert (deep= [] (html/flashes @{}))
        "no session, no flashes — a layout may call it unconditionally")

(def [ok err] (protect (html/flash! @{} :ok "x")))
(assert (not ok) "flash! without a session is an error naming what to enable")
(assert (string/find "session" err))
(assert (string/find ":http" err) "and the config that enables it")

(print "page-test: ok")
