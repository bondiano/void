### blog/views — plain functions returning hiccup.
###
### Nothing here knows about HTTP: handlers hand these to `html/page`
### and `html/fragment`, and the :void.html/render middleware turns the
### result into bytes on the way out. Forms are projections of the
### schemas in ./entities, so a field added there shows up here with
### its validation already attached.
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx/hx :as hx)
(import void/db :as db)
(import ./entities :as e)

(defn layout
  "The one page frame."
  [content _context]
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "void blog"]
     [:script {:src "https://unpkg.com/htmx.org@2.0.7"}]]
    [:body
     [:header [:a {:href "/"} [:h1 "void blog"]]]
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
  "The new-article form: one schema over two entities (see
  entities/NewArticle)."
  [&opt values errors]
  (form/form e/NewArticle
    {:action "/articles"
     :values values
     :errors errors
     :fields {:body {:control :textarea}
              :name {:label "Author"}
              :email {:label "Author email"}}
     :submit "Publish"
     :attrs (hx/post "/articles" :target "#index" :swap :outer-html)}))

(defn index-view
  "GET / — the list plus the publish form."
  [articles &opt values errors]
  [:div {:id "index"}
   (article-list articles)
   [:h2 "Publish"]
   (new-article-form values errors)])

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
   [:p {:class "actions"}
    [:a {:href (string "/articles/" (article :id) "/edit")} "Edit"]
    " "
    [:button (hx/delete (string "/articles/" (article :id))
                        :target "body" :swap :outer-html
                        :confirm nil)
     "Delete"]]
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
