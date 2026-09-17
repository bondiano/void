(defn up
  {:params [] :ret [{:keyword :any}]}
  "Create the comments table and the index its article-page query
  reads by."
  []
  [{:create-table "comments"
    :columns [[:id :serial {:primary-key true}]
              [:article-id :int {:null false :refs [:articles :id]
                                 :on-delete :cascade}]
              [:author-name :text {:null false}]
              [:body :text {:null false}]
              [:created-at :text {:null false}]]}

   {:create-index "comments_article_idx"
    :on "comments" :columns [:article-id]}])

(defn down
  {:params [] :ret {:keyword :any}}
  "Drop the comments table."
  []
  {:drop-table "comments"})
