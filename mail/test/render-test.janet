(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/html :as html)
(import void/mail :as mail)
(import void/mail/render :as render)
(require "void/html/init")

(log/set-level! "void" :error)

(def boot (test/start! {:plugins ["void/http/init" "void/html/init" "void/mail/init"]
                        :only [:http/kernel] :profile :test
                        :config {:env @{}
                                 :cli {:log {:level :error}
                                       :http {:port 0 :access-log false}
                                       :mail {:transport :memory
                                              :from "void <no-reply@example.com>"
                                              :base-url "https://example.com/"}}}}))

(defn- layout [content _]
  [:html [:body {:style "margin: 0"} content]])

(defer (test/stop! boot)
  # -- the engine is the one the composition already selected ----------
  (assert (deep= @[:hiccup :temple] (sorted (keys (html/current-context :engines))))
          "a letter is rendered by the same registry as a page — an engine contributed for pages works for mail without knowing mail exists")
  (assert (not (first (protect (mail/render-view [:p "x"] {:engine :handlebars}))))
          "and an engine nobody contributed is named in the error")

  (assert (= "<p>hello</p>" (mail/render-view [:p "hello"])))
  (assert (= "<html><body style=\"margin: 0\"><p>hi</p></body></html>"
             (mail/render-view [:p "hi"] {:layout layout}))
          "a layout is a function and travels on the message, exactly where html/page takes one")

  # -- a letter has no origin ------------------------------------------
  (assert (= "https://example.com/login" (mail/url "/login")))
  (assert (= "https://example.com/login" (mail/url "login")))
  (assert (= "https://other.example/x" (mail/url "https://other.example/x"))
          "a link to somewhere else is not mangled")
  (assert (= "mailto:a@b.co" (mail/url "mailto:a@b.co")))
  (assert (string/has-prefix? "https://example.com/assets/" (mail/asset "css/app.css"))
          "and an asset is the same file the pages link to, addressed from outside")

  (assert (empty? (render/relative-urls "<a href=\"https://x/y\">x</a><a href=\"#top\">t</a>")))
  (assert (deep= @["/login" "/logo.png"]
                 (render/relative-urls "<a href=\"/login\">x</a><img src=\"/logo.png\">")))

  (def [ok err] (protect (mail/send {:to "a@b.co" :subject "s"
                                     :view [:a {:href "/login"} "sign in"]})))
  (assert (not ok))
  (assert (string/find "resolves against nothing in a mail client" (string err))
          "a relative link is refused where it is written, not discovered in an inbox")

  (assert (mail/render-view [:a {:href "/login"} "x"] {:check false})
          "a preview that is not going anywhere may opt out")

  # -- rendering happens before the message is normalized ---------------
  (def bytes (mail/preview {:to "a@b.co" :subject "s"
                            :view [:p "hello"] :layout layout}))
  (assert (string/find "<html><body" bytes) "the layout is in the letter")
  (assert (string/find "Content-Type: text/html" bytes))
  (assert (string/find "Content-Type: text/plain" bytes)
          "and the text part is generated from it"))

# -- without void/html booted -------------------------------------------

(set html/current-context nil)
(assert (not (first (protect (mail/render-view [:p "x"]))))
        "a template needs the view layer, and says so rather than failing on a nil lookup")
