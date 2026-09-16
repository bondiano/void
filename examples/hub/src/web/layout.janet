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
  (def link "text-sm text-slate-400 no-underline transition hover:text-slate-100")
  (if (auth/current-user)
    [:div {:class "flex flex-wrap items-center gap-x-4 gap-y-2"}
     # the claim comes off the identity, which void/auth-http re-read
     # from the store on this request — no second query for a greeting
     [:span {:class "text-sm text-slate-500"}
      "Signed in as "
      [:strong {:class "font-mono font-medium text-emerald-400"}
       (or (auth/claim :email) (auth/subject))]]
     [:a {:class link :href "/verify"} "Your address"]
     (form/form {} {:action "/logout" :submit "Sign out"
                    :attrs {:class "quiet-form contents"}})]
    [:div {:class "flex flex-wrap items-center gap-x-4 gap-y-2"}
     [:a {:class link :href "/login"} "Sign in"]
     [:a {:class link :href "/register"} "Create an account"]]))

(defn layout
  "The frame every page of this application that is not the desk goes
  in."
  [content context]
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "hub"]
     # the compiled stylesheet: the logical name in development, the
     # fingerprinted one after `void assets build` — the markup does
     # not know which (config/default.janet)
     [:link {:rel "stylesheet" :href (html/asset "app.css")}]]
    [:body {:class "min-h-dvh bg-slate-950 text-slate-200 antialiased"}
     [:header {:class "border-b border-white/5 bg-slate-900/50"}
      [:div {:class "mx-auto flex max-w-md flex-wrap items-center justify-between gap-3 px-6 py-4"}
       [:a {:class "font-mono text-sm font-semibold tracking-widest text-slate-100 no-underline"
            :href "/"}
        "HUB"]
       (who-bar)]]
     [:main {:class "mx-auto max-w-md px-6 py-16"} content]]))

(defn page
  "Hiccup in the frame — what a controller hands back as a response
  body."
  [content]
  (html/page content {:layout layout}))
