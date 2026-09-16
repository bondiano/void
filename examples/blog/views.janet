### blog/views — plain functions returning hiccup.
###
### Nothing here knows about HTTP: handlers hand these to `html/page`
### and `html/fragment`, and the :void.html/render middleware turns the
### result into bytes on the way out. Forms are projections of the
### schemas in ./entities, so a field added there shows up here with
### its validation already attached.
###
### Two wave-3 seams pass through here without a line of plumbing. Every
### non-GET form below renders a CSRF field, because `void/security` binds
### the slot `form/form` has been splicing since wave 1 — there is no call
### to make. And the Edit control asks `authz/can?` with the same policy
### the route enforces, so a link that is drawn and a request that is
### allowed cannot drift apart.
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx/hx :as hx)
(import void/db :as db)
(import void/auth :as auth)
(import void/authz :as authz)
(import void/security :as security)
(import ./entities :as e)

(defn who-bar
  "Who is signed in, and the way out."
  []
  (if-let [id (auth/current-user)]
    [:p {:class "flex items-center gap-3 text-sm text-stone-500"}
     "Signed in as "
     [:strong {:class "font-medium text-stone-900"}
      (or (auth/claim :name) (auth/subject))]
     (form/form {} {:action "/sign-out" :submit "Sign out"
                    :attrs {:class "quiet-form contents"}})]
    [:p {:class "text-sm text-stone-400"} "Not signed in."]))

(defn layout
  ``The one page frame.

  The two `<meta>` tags and the `hx-headers:inherited` attribute are
  what let a request htmx makes on its own — the Delete button below
  has no form around it — carry the CSRF token. `security/htmx-meta`
  builds them from the same token the form fields get; the suffix is
  htmx 4's, which inherits an attribute only where the name asks for
  it.``
  [content context]
  (def req (get context :request))
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "void blog"]
     # the compiled stylesheet: the logical name in development, the
     # fingerprinted one after `void assets build` — the markup does
     # not know which (config/default.janet)
     [:link {:rel "stylesheet" :href (html/asset "app.css")}]
     (when req (security/htmx-meta req))
     # pinned to the file, with its hash — the CDN serves this exact
     # script or the browser refuses to run what it got instead
     [:script {:src "https://unpkg.com/htmx.org@4.0.0/dist/htmx.min.js"
               :integrity "sha384-BvJpBiO8Kh31EqtJe5DRIeWrHWnCGkwytKs9NKFi86Hhw96dEqdEMzZDeK9iEGTc"
               :crossorigin "anonymous"}]]
    [:body (merge (if req (security/htmx-attrs req) {})
                  {:class "min-h-dvh bg-stone-50 text-stone-900 antialiased"})
     [:header {:class "border-b border-stone-200 bg-white"}
      [:div {:class "mx-auto flex max-w-2xl flex-wrap items-baseline justify-between gap-3 px-6 py-6"}
       [:a {:href "/" :class "no-underline"}
        [:h1 {:class "m-0 font-display text-2xl font-normal tracking-tight text-stone-900"}
         "void blog"]]
       (who-bar)]]
     # what the last write said about itself, shown once
     (when req (html/flash-view req))
     [:main {:class "mx-auto max-w-2xl px-6 py-12"} content]]))

# -- the index -----------------------------------------------------------

(defn article-row
  ``One line of the article list. `db/rel` is a table lookup when the
  relation was preloaded and an N+1 in the making when it was not —
  which is exactly why it is the accessor and not a plain key
.``
  [article]
  [:li {:class "border-b border-stone-200 py-5 last:border-0"}
   [:a {:class "font-display text-xl leading-snug text-stone-900 no-underline hover:text-stone-600"
        :href (string "/articles/" (article :id))}
    (article :title)]
   [:p {:class "mt-1 text-sm text-stone-500"}
    "by " (get (db/rel article :author) :name "unknown")
    " · " (get article :comment-count 0) " comments"]])

(defn article-list
  "The #articles fragment — the cached read of this application."
  [articles]
  [:ul {:id "articles" :class "m-0 list-none p-0"}
   (if (empty? articles)
     [:li {:class "rounded-xl border border-dashed border-stone-300 px-5 py-10 text-center text-stone-400"}
      "Nothing published yet."]
     (seq [a :in articles] (article-row a)))])

(defn new-article-form
  ``The publish form. In wave 2 it carried the author's name and email
  as well; now the author is whoever is signed in, so the form is the
  article — and the hidden CSRF field void/security splices in.``
  [&opt values errors]
  (form/form e/NewArticle
    {:action "/articles"
     :values values
     :errors errors
     :fields {:body {:control :textarea}}
     :submit "Publish"
     :attrs (hx/post "/articles" :target "#index" :swap :outer-html)}))

(defn sign-in-form
  "Two fields and a password."
  [&opt values]
  (form/form e/Credentials
    {:action "/sign-in"
     :values values
     :fields {:password {:type "password"}}
     :submit "Sign in"}))

(defn magic-link-form
  ``The other way in: an address, and a link arrives by mail
  (void/mail-auth). The visitor types nothing they have to remember,
  and the blog stores no password for them until they want one.``
  [&opt values]
  (form/form e/MagicLink
    {:action "/sign-in/magic"
     :values values
     :submit "Mail me a sign-in link"}))

(defn register-form
  "The same, plus a name — the account this blog knows an author by."
  [&opt values errors]
  (form/form e/Registration
    {:action "/register"
     :values values
     :errors errors
     :fields {:password {:type "password"}}
     :submit "Create an account"}))

(defn index-view
  ``GET / — the list, and then either the publish form or the way to
  get one. `state` carries whatever the handler wants re-rendered:
  :values/:errors for the article form, :register/:sign-in for the
  other two, :message for the one line a failed sign-in is allowed to
  say.``
  [articles &opt state]
  (default state {})
  [:div {:id "index"}
   (article-list articles)
   (when-let [msg (get state :message)]
     [:p {:class "mt-8 rounded-lg border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900"}
      msg])
   (if (auth/current-user)
     [:div {:id "publish" :class "mt-12 rounded-xl border border-stone-200 bg-white p-6"}
      [:h2 {:class "m-0 mb-5 font-display text-xl font-normal"} "Publish"]
      (new-article-form (get state :values) (get state :errors))]
     [:div {:id "join" :class "mt-12 grid gap-4"}
      # three ways in, one card each — a column on a phone, and the
      # same column on a laptop, because a sign-in form is not wide
      [:section {:class "rounded-xl border border-stone-200 bg-white p-6"}
       [:h2 {:class "m-0 mb-5 font-display text-xl font-normal"} "Sign in"]
       (sign-in-form (get state :sign-in))]
      [:section {:class "rounded-xl border border-stone-200 bg-white p-6"}
       [:h2 {:class "m-0 mb-1 font-display text-xl font-normal"} "Or get a link by mail"]
       [:p {:class "mb-5 mt-0 text-sm text-stone-500"} "It works once."]
       (magic-link-form (get state :magic-link))]
      [:section {:class "rounded-xl border border-stone-200 bg-white p-6"}
       [:h2 {:class "m-0 mb-5 font-display text-xl font-normal"} "Or create an account"]
       (register-form (get state :register) (get state :register-errors))]])])

(defn render-index
  "The index as a page — what three handlers answer with."
  [articles &opt state]
  (html/page (index-view articles state) {:layout layout}))

# -- one article ---------------------------------------------------------

(defn comment-item [c]
  [:li {:class "border-l-2 border-stone-200 py-2 pl-4"}
   [:p {:class "m-0 text-sm font-medium text-stone-900"} (c :author-name)]
   [:p {:class "m-0 mt-0.5 leading-relaxed text-stone-700"} (c :body)]])

(defn article-view
  ``GET /articles/:id — the article with its author and comments, both
  preloaded, plus the comment form. `counted` is the counter column;
  it trails the comment list by however long the job takes, which is
  the honest thing for a page to show.``
  [article &opt values errors]
  [:div {:id "article"}
   [:article
    [:h2 {:class "m-0 font-display text-3xl font-normal leading-tight tracking-tight"}
     (article :title)]
    [:p {:class "mt-2 text-sm text-stone-500"}
     "by " (get (db/rel article :author) :name "unknown")
     " · " (get article :created-at "")]
    [:p {:class "mt-6 whitespace-pre-line text-lg leading-relaxed text-stone-800"}
     (article :body)]]
   # the same policy the routes enforce, asked here: a control that is
   # drawn and a request that is allowed come from one source, so neither
   # can drift. A reader, or another author, sees nothing to click rather
   # than a button that answers 403
   (when (authz/can? :articles/own {:resource article})
     [:p {:class "mt-6 flex items-center gap-2"}
      [:a {:class "rounded-lg border border-stone-300 px-4 py-2 text-sm font-medium text-stone-700 no-underline transition hover:border-stone-900 hover:text-stone-900"
           :href (string "/articles/" (article :id) "/edit")}
       "Edit"]
      [:button (merge (hx/delete (string "/articles/" (article :id))
                                 :target "body" :swap :outer-html
                                 :confirm nil)
                      {:class "rounded-lg border border-transparent px-4 py-2 text-sm font-medium text-red-700 transition hover:border-red-200 hover:bg-red-50"})
       "Delete"]])
   [:h3 {:class "mb-4 mt-12 border-t border-stone-200 pt-8 text-sm font-semibold uppercase tracking-widest text-stone-400"}
    "Comments (" (get article :comment-count 0) " counted)"]
   [:ul {:id "comments" :class "m-0 flex list-none flex-col gap-4 p-0"}
    (let [comments (db/rel article :comments)]
      (if (empty? comments)
        [:li {:class "text-stone-400"} "No comments yet."]
        (seq [c :in comments] (comment-item c))))]
   (form/form e/NewComment
     {:action (string "/articles/" (article :id) "/comments")
      :values values
      :errors errors
      :fields {:body {:control :textarea}}
      :submit "Comment"
      :attrs (merge {:class "mt-8 rounded-xl border border-stone-200 bg-white p-6"}
                    (hx/post (string "/articles/" (article :id) "/comments")
                             :target "#article" :swap :outer-html))})])

(defn edit-view
  "GET /articles/:id/edit — the two columns `save!` may change."
  [article &opt values errors]
  [:div {:id "edit"}
   [:h2 {:class "m-0 mb-6 font-display text-3xl font-normal tracking-tight"} "Edit"]
   (form/form e/EditArticle
     {:action (string "/articles/" (article :id))
      :values (or values article)
      :errors errors
      :fields {:body {:control :textarea}}
      :submit "Save"})
   [:p {:class "mt-6"}
    [:a {:class "text-sm text-stone-500 hover:text-stone-900"
         :href (string "/articles/" (article :id))}
     "Cancel"]]])
