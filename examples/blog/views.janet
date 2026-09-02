### blog/views — plain functions returning hiccup.
###
### Nothing here knows about HTTP: handlers hand these to `html/page`
### and `html/fragment`, and the :void.html/render middleware turns the
### result into bytes on the way out. Forms are projections of the
### schemas in ./entities, so a field added there shows up here with
### its validation already attached.
###
### Two wave-3 seams pass through here without a line of plumbing.
### Every non-GET form below renders a CSRF field, because
### `void/security` binds the slot `form/form` has been splicing since
### wave 1 — there is no call to make. And the Edit control asks
### `authz/can?` with the same policy the route enforces, so a link
### that is drawn and a request that is allowed cannot drift apart
### (ADR-0024).
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
    [:p {:class "who"}
     "Signed in as " [:strong (or (auth/claim :name) (auth/subject))] " "
     (form/form {} {:action "/sign-out" :submit "Sign out"})]
    [:p {:class "who"} "Not signed in."]))

(defn layout
  ``The one page frame.

  The two `<meta>` tags and the `hx-headers:inherited` attribute are
  what let a request htmx makes on its own — the Delete button below
  has no form around it — carry the CSRF token. `security/htmx-meta`
  builds them from the same token the form fields get; the suffix is
  htmx 4's, which inherits an attribute only where the name asks for
  it (ADR-0041).``
  [content context]
  (def req (get context :request))
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "void blog"]
     (when req (security/htmx-meta req))
     [:script {:src "https://unpkg.com/htmx.org@4.0.0"}]]
    [:body (if req (security/htmx-attrs req) {})
     [:header [:a {:href "/"} [:h1 "void blog"]] (who-bar)]
     [:main content]]))

# -- the index -----------------------------------------------------------

(defn article-row
  ``One line of the article list. `db/rel` is a table lookup when the
  relation was preloaded and an N+1 in the making when it was not —
  which is exactly why it is the accessor and not a plain key
  (ADR-0009).``
  [article]
  [:li {:class "article"}
   [:a {:href (string "/articles/" (article :id))} (article :title)]
   [:span {:class "byline"} " by " (get (db/rel article :author) :name "unknown")]
   [:span {:class "comment-count"}
    " · " (get article :comment-count 0) " comments"]])

(defn article-list
  "The #articles fragment — the cached read of this application."
  [articles]
  [:ul {:id "articles"}
   (if (empty? articles)
     [:li {:class "empty"} "Nothing published yet."]
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
   (when-let [msg (get state :message)] [:p {:class "message"} msg])
   (if (auth/current-user)
     [:div {:id "publish"}
      [:h2 "Publish"]
      (new-article-form (get state :values) (get state :errors))]
     [:div {:id "join"}
      [:h2 "Sign in"]
      (sign-in-form (get state :sign-in))
      [:h2 "Or get a link by mail"]
      (magic-link-form (get state :magic-link))
      [:h2 "Or create an account"]
      (register-form (get state :register) (get state :register-errors))])])

(defn render-index
  "The index as a page — what three handlers answer with."
  [articles &opt state]
  (html/page (index-view articles state) {:layout layout}))

# -- one article ---------------------------------------------------------

(defn comment-item [c]
  [:li {:class "comment"}
   [:strong (c :author-name)] ": " (c :body)])

(defn article-view
  ``GET /articles/:id — the article with its author and comments, both
  preloaded, plus the comment form. `counted` is the counter column;
  it trails the comment list by however long the job takes, which is
  the honest thing for a page to show.``
  [article &opt values errors]
  [:div {:id "article"}
   [:article
    [:h2 (article :title)]
    [:p {:class "byline"} "by " (get (db/rel article :author) :name "unknown")
     " · " (get article :created-at "")]
    [:p (article :body)]]
   # the same policy the routes enforce, asked here: a control that is
   # drawn and a request that is allowed come from one source, so
   # neither can drift (ADR-0024). A reader, or another author, sees
   # nothing to click rather than a button that answers 403
   (when (authz/can? :articles/own {:resource article})
     [:p {:class "actions"}
      [:a {:href (string "/articles/" (article :id) "/edit")} "Edit"]
      " "
      [:button (hx/delete (string "/articles/" (article :id))
                          :target "body" :swap :outer-html
                          :confirm nil)
       "Delete"]])
   [:h3 "Comments (" (get article :comment-count 0) " counted)"]
   [:ul {:id "comments"}
    (let [comments (db/rel article :comments)]
      (if (empty? comments)
        [:li {:class "empty"} "No comments yet."]
        (seq [c :in comments] (comment-item c))))]
   (form/form e/NewComment
     {:action (string "/articles/" (article :id) "/comments")
      :values values
      :errors errors
      :fields {:body {:control :textarea}}
      :submit "Comment"
      :attrs (hx/post (string "/articles/" (article :id) "/comments")
                      :target "#article" :swap :outer-html)})])

(defn edit-view
  "GET /articles/:id/edit — the two columns `save!` may change."
  [article &opt values errors]
  [:div {:id "edit"}
   [:h2 "Edit"]
   (form/form e/EditArticle
     {:action (string "/articles/" (article :id))
      :values (or values article)
      :errors errors
      :fields {:body {:control :textarea}}
      :submit "Save"})
   [:p [:a {:href (string "/articles/" (article :id))} "Cancel"]]])
