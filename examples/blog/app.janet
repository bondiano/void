### blog/app — the application plugin: routes, handlers, manifest.
###
### Everything a CRUD application needs is here and nowhere else: the
### domain is ./entities, the background work is ./jobs, the markup is
### ./views. What this file adds is the request path — and it never
### names a database engine. `:void.db/txn true` on a route is the
### whole of transaction management (void/db-http); `db/query` with an
### explicit `:preload` is the whole of the N+1 story; `cache/remember`
### is the whole of the caching one.
###
### Handlers are registered as symbols, so a redefinition in the repl —
### or a save with `void dev` running — is live (ADR-0002).
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/errors :as errors)
(import void/html :as html)
(import void/html/form :as form)
(import void/htmx :as htmx)
(import void/db :as db)
(import void/cache :as cache)
(import void/jobs :as jobs)
(import ./entities :as e)
(import ./views :as views)
(import ./jobs :as blog-jobs)

# -- reads ---------------------------------------------------------------

(defn recent-articles
  ``The article list, through the cache. The read underneath is one
  query plus one batched IN for the authors — `:preload` is explicit
  because the alternative is an N+1 nobody notices until production
  (ADR-0009).``
  []
  (cache/remember blog-jobs/index-cache-key {:ttl 60}
    (fn load-index []
      (log/debug "index cache miss" :ns "blog.app")
      (db/query e/Article {:order-by [[:created-at :desc] [:id :desc]]
                           :limit 50
                           :preload [:author]}))))

(defn- load-article
  "One article with its author and comments, or a 404."
  [req]
  (def id (scan-number (get-in req [:params :id] "")))
  (unless id (errors/abort 404))
  (or (db/find e/Article id {:preload [:author :comments]})
      (errors/abort 404)))

(defn- invalidate-index! []
  (cache/forget blog-jobs/index-cache-key))

# -- handlers ------------------------------------------------------------

(defn home
  "GET / — the list and the publish form."
  [req]
  (html/page (views/index-view (recent-articles)) {:layout views/layout}))

(defn create-article
  ``POST /articles — one form, two entities, one transaction. The
  route carries :void.db/txn, so the author lookup, the author insert
  and the article insert either all land or none do; the wrapper
  commits when the handler returns and rolls back when it throws.``
  [req]
  (def result (form/check e/NewArticle (req :form)))
  (if (empty? (result :errors))
    (do
      (def v (result :value))
      (def author
        (or (db/one e/Author {:where [:= :email (v :email)]})
            (db/insert! e/Author {:name (v :name) :email (v :email)})))
      (db/insert! e/Article {:author-id (author :id)
                             :title (v :title)
                             :body (v :body)
                             :comment-count 0
                             :created-at (e/now)})
      (invalidate-index!)
      (html/page (views/index-view (recent-articles)) {:layout views/layout}))
    (html/page (views/index-view (recent-articles) (req :form) (result :errors))
               {:layout views/layout})))

(defn show-article
  "GET /articles/:id — the article, its author and its comments."
  [req]
  (html/page (views/article-view (load-article req)) {:layout views/layout}))

(defn edit-article
  "GET /articles/:id/edit — the form over the columns save! may touch."
  [req]
  (html/page (views/edit-view (load-article req)) {:layout views/layout}))

(defn update-article
  ``POST /articles/:id — dirty tracking: the instance is changed in
  place and `save!` writes a partial UPDATE of exactly the columns
  that differ from the snapshot it was loaded with, or no statement at
  all when nothing did.``
  [req]
  (def article (load-article req))
  (def result (form/check e/EditArticle (req :form)))
  (if (empty? (result :errors))
    (do
      (merge-into article (result :value))
      (def changed (db/changes article))
      (db/save! article)
      (unless (empty? changed)
        (log/info "article updated" :ns "blog.app"
                  :article (article :id) :columns (sorted (keys changed)))
        (invalidate-index!))
      (ring/redirect (string "/articles/" (article :id))))
    (html/page (views/edit-view article (req :form) (result :errors))
               {:layout views/layout})))

(defn delete-article
  "DELETE /articles/:id — the comments go with it (ON DELETE CASCADE)."
  [req]
  (def article (load-article req))
  (db/delete! e/Article (article :id))
  (invalidate-index!)
  (if (htmx/request? req)
    (htmx/redirect (ring/response 204) "/")
    (ring/redirect "/")))

(defn create-comment
  ``POST /articles/:id/comments — the write is synchronous, the
  bookkeeping is not: the counter on `articles` is recomputed by
  :recount-comments on the maintenance queue, which also drops the
  cached index. :unique :args means a burst of comments on one article
  is one recount.``
  [req]
  (def article (load-article req))
  (def result (form/check e/NewComment (req :form)))
  (if (empty? (result :errors))
    (do
      (db/insert! e/Comment (merge (result :value)
                                   {:article-id (article :id)
                                    :created-at (e/now)}))
      (jobs/enqueue :recount-comments (article :id))
      (html/page (views/article-view (load-article req)) {:layout views/layout}))
    (html/page (views/article-view article (req :form) (result :errors))
               {:layout views/layout})))

# -- routes --------------------------------------------------------------

(router/defroutes :blog/routes
  (GET "/" home)
  (POST "/articles" create-article
        {:name :articles/create :void.db/txn true :void.htmx/partial true})
  (GET "/articles/:id" show-article {:name :articles/show})
  (GET "/articles/:id/edit" edit-article {:name :articles/edit})
  (POST "/articles/:id" update-article
        {:name :articles/update :void.db/txn true})
  (DELETE "/articles/:id" delete-article
          {:name :articles/delete :void.db/txn true})
  (POST "/articles/:id/comments" create-comment
        {:name :comments/create :void.db/txn true :void.htmx/partial true}))

# -- manifest ------------------------------------------------------------

(plugin/defplugin blog/app
  :doc "blog — a CRUD application on void/db, void/jobs and void/cache."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"
             :void/db ">=0.0.1" :void/db-http ">=0.0.1"
             :void/cache ">=0.0.1" :void/jobs ">=0.0.1"})
