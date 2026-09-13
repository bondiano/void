(import ../test-support/paths)
(import void/html/hiccup :as hiccup)
(import void/test :as test)

# -- rendering basics ----------------------------------------------------

(assert (= "<p>hi</p>" (hiccup/render-string [:p "hi"])))
(assert (= `<p class="a">hi</p>` (hiccup/render-string [:p {:class "a"} "hi"])))
(assert (= "<p>&lt;b&gt; &amp; &#39;</p>"
           (hiccup/render-string [:p "<b> & '"]))
        "text children are escaped")
(assert (= "<p><b>raw</b></p>"
           (hiccup/render-string [:p (hiccup/raw "<b>raw</b>")]))
        "raw splices unescaped")
(assert (= "<br/>" (hiccup/render-string [:br])) "void elements self-close")
(assert (= "<p></p>" (hiccup/render-string [:p nil])) "nil children disappear")
(assert (= "<p>ab</p>" (hiccup/render-string [:p @["a" "b"]]))
        "arrays are fragments")

# nil attributes are dropped, so conditional attributes read naturally
(assert (= `<input type="text"/>`
           (hiccup/render-string [:input {:type "text" :disabled nil}])))
(assert (= `<input disabled type="text"/>`
           (hiccup/render-string [:input {:type "text" :disabled true}]))
        "true is a bare attribute")
(assert (= `<input type="text"/>`
           (hiccup/render-string [:input {:type "text" :disabled false}]))
        "false drops the attribute, as nil does")
(assert (= `<p class="a b" style="color:red;margin:0"></p>`
           (hiccup/render-string [:p {:class ["a" nil "b"] :style {:margin 0 :color "red"}}]))
        ":class and :style take data")
(assert (not (first (protect (hiccup/render-string [:p {"a b" 1}]))))
        "an attribute name with a space is two attributes, so it is an error")

# -- a function where a leaf should be -------------------------------------

(defn who-bar [] [:nav "who"])
(assert (= "<div><nav>who</nav></div>" (hiccup/render-string [:div [who-bar]])))
(def [ok err] (protect (hiccup/render-string [:div who-bar])))
(assert (and (not ok) (string/find "function leaf" err))
        "a component named without its brackets is an error, not a call with the buffer")
(assert (hiccup/raw? (hiccup/raw "<b>")))
(assert (not (hiccup/raw? {:void.html/raw 1})))

# -- json-script ---------------------------------------------------------

(assert (= `<script id="cfg" type="application/json">{"s":"\u003c/script\u003e"}</script>`
           (hiccup/render-string (hiccup/json-script "cfg" {:s "</script>"})))
        "a data island cannot close its own tag")

# -- components as functions ---------------------------------------------

(defn card [attrs & children]
  [:div {:class (hiccup/classes "card" (attrs :variant))}
   [:div {:class "card-body"} children]])

(assert (= `<div class="card danger"><div class="card-body">boom</div></div>`
           (hiccup/render-string [card {:variant "danger"} "boom"]))
        "a tuple with a function head is a component call")

(defn item [text] [:li text])

(assert (= "<ul><li>a</li><li>b</li></ul>"
           (hiccup/render-string [:ul (map |[item $] ["a" "b"])]))
        "components nest through fragments")

(defn wrapper [& children] @[[:hr] children])

(assert (= "<hr/><p>x</p>"
           (hiccup/render-string [wrapper [:p "x"]]))
        "a component may return a fragment, & children splice as one too")

(assert (not (first (protect (hiccup/render-string [:p {:a 1} [:i {:b 2}] {:c 3}]))))
        "a dictionary outside attribute position is an error")

# -- classes -------------------------------------------------------------

(assert (= "btn btn-lg active"
           (hiccup/classes "btn" (when true :btn-lg) (when false :hidden)
                           nil {:active true :disabled false})))
(assert (= "" (hiccup/classes nil false)))

# -- html5 / layouts as functions ----------------------------------------

(defn base-layout [content context]
  (hiccup/html5 {:lang "en"}
    [:head [:title (get context :title "void")]]
    [:body content]))

(def page (hiccup/render-string (base-layout [:h1 "hello"] {:title "home"})))
(assert (string/has-prefix? "<!DOCTYPE html>" page))
(assert (string/find `<html lang="en">` page))
(assert (string/find "<title>home</title>" page))
(assert (string/find "<body><h1>hello</h1></body>" page))

# -- snapshot testing (void/test) ----------------------------------------

(assert (test/snapshot "hiccup-layout"
                       (hiccup/render-string (base-layout [:h1 "hello"] {:title "home"}))))

(defn order-row [order]
  [:tr [:td (order :id)] [:td (order :title)]])

(assert (test/snapshot "hiccup-orders-table"
                       (hiccup/render-string
                         [:table
                          [:thead [:tr [:th "id"] [:th "title"]]]
                          [:tbody (map |[order-row $]
                                       [{:id 1 :title "widget"}
                                        {:id 2 :title "<gadget>"}])]])))

(print "hiccup-test: ok")
