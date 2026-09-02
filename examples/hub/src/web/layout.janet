### hub/web/layout — the page frame.
###
### The one file that knows about more than one module, which is what a
### frame is: a header that says who is signed in, and a main element
### the module's view fills. It is small because this application has
### almost no pages — receiving is a machine talking to a machine, the
### desk is `void/admin`'s own layout, and what is left is the six
### account pages `void make auth` generated.
###
### It began inside that generated file (`layout` and `who-bar` were
### written there so its pages would render the moment they existed) and
### moved here when this example took the shop's shape: a frame shared
### by two modules is not a layer of one of them.
(import void/auth :as auth)
(import void/html :as html)
(import void/html/form :as form)

(defn who-bar
  "Who is signed in, and the way out."
  []
  (if (auth/current-user)
    [:p {:class "who"}
     # the claim comes off the identity, which void/auth-http re-read
     # from the store on this request — no second query for a greeting
     "Signed in as " [:strong (or (auth/claim :email) (auth/subject))] " · "
     [:a {:href "/verify"} "Your address"] " "
     (form/form {} {:action "/logout" :submit "Sign out"})]
    [:p {:class "who"}
     [:a {:href "/login"} "Sign in"] " · "
     [:a {:href "/register"} "Create an account"]]))

(defn layout
  "The frame every page of this application that is not the desk goes
  in."
  [content context]
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "hub"]]
    [:body
     [:header (who-bar)]
     [:main content]]))

(defn page
  "Hiccup in the frame — what a controller hands back as a response
  body."
  [content]
  (html/page content {:layout layout}))
