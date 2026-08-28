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
### Wave 3 added three lines of the same kind. `:void.auth/access
### :required` is the whole of "you must be signed in".
### `:void.authz/policy :articles/own` plus `:void.authz/resource` is
### the whole of "and it must be yours" — the policy underneath is a
### pure function of a context, tested without a database in
### test/auth-test.janet. And nothing at all is the whole of CSRF: the
### form helper renders the token because `void/security` bound the
### slot `void/html` has carried since wave 1.
###
### The application's posture is `[:authz :default :deny]`
### (config/default.janet), so every route below names a policy —
### `:public` where it means it. A route that forgets one does not
### serve traffic and then get audited: it fails the boot.
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
(import void/auth :as auth)
(import void/auth/http :as auth-http)
(import void/authz :as authz)
(import ./entities :as e)
(import ./views :as views)
(import ./jobs :as blog-jobs)

# -- who is asking -------------------------------------------------------

(defn current-author-id
  ``The id of the signed-in author, or nil. The subject is
  `"author:42"` — `[:auth-db :users :subject-kind]` is the `author`
  half — so this is the one place the application unpacks it.``
  []
  (when-let [id (auth/current-user)]
    (scan-number (last (auth/subject-of (id :subject))))))

(defn article-resource
  ``What the policy on the edit routes decides about: the row itself.
  Route metadata carries a function rather than a symbol, because a
  route entry does not keep the environment of the module that
  declared it (ADR-0024 §5).``
  [req]
  (when-let [id (scan-number (get-in req [:params :id] ""))]
    (db/find e/Article id)))

(authz/defpolicy :articles/own
  ``An author edits and deletes their own articles, and nobody else's.

  A pure function of a context: `:subject/id` falls back to the id
  half of the subject string and `:resource/author-id` to a key of the
  row, so this policy needs no attribute provider and no
  configuration. It is also the whole of the row-level check — the
  same call answers the middleware on the route and the template
  deciding whether to draw an Edit link (views/article-view), which is
  how the button that is not there and the request that would fail
  come from one source.``
  [ctx]
  (or (= (authz/attr ctx :subject/id)
         (string (authz/attr ctx :resource/author-id)))
      "not the author of this article"))

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
  "GET / — the list, and either the publish form or the way to sign in."
  [req]
  (views/render-index (recent-articles) {}))

(defn create-article
  ``POST /articles — the author is whoever is signed in.

  In wave 2 this handler took a name and an email off the form and
  invented an author when it did not recognise them; that was one form
  over two entities and one transaction. Wave 3 deleted the
  interesting half of it: `:void.auth/access :required` on the route
  means there is an identity by the time this runs, and an identity is
  not something a form can claim to be. The transaction stays, because
  the article and the cache invalidation still belong together.``
  [req]
  (def result (form/check e/NewArticle (req :form)))
  (if (empty? (result :errors))
    (do
      (def v (result :value))
      (db/insert! e/Article {:author-id (current-author-id)
                             :title (v :title)
                             :body (v :body)
                             :comment-count 0
                             :created-at (e/now)})
      (invalidate-index!)
      (views/render-index (recent-articles) {}))
    (views/render-index (recent-articles) {:values (req :form)
                                           :errors (result :errors)})))

# -- signing in ----------------------------------------------------------

(defn register
  ``POST /register — an author with a password.

  `auth/hash-password` produces a PHC string: the algorithm and its
  cost travel inside the value, so raising the cost later is a config
  change rather than a migration nobody can write (ADR-0023 §4). The
  sign-in that follows goes through the ordinary password path rather
  than trusting what was just inserted.``
  [req]
  (def result (form/check e/Registration (req :form)))
  (def v (result :value))
  (def taken (and (empty? (result :errors))
                  (db/one e/Author {:where [:= :email (v :email)]})))
  (cond
    (not (empty? (result :errors)))
    (views/render-index (recent-articles) {:register (req :form)
                                           :register-errors (result :errors)})

    taken
    (views/render-index (recent-articles)
                        {:register (req :form)
                         :message "That email already has an account — sign in instead."})

    (do
      (db/insert! e/Author {:name (v :name)
                            :email (v :email)
                            :password-hash (auth/hash-password (v :password))})
      (def check (auth/check-password (auth/user-store)
                                      {:email (v :email) :password (v :password)}))
      (auth-http/login! req (check :identity))
      (ring/redirect "/"))))

(defn sign-in
  ``POST /sign-in — the password path, and nothing else.

  Whatever went wrong, the page says the same thing: `check-password`
  distinguishes an unknown address from a wrong password and spends
  the same time on both (it hashes even when there is no user), and
  telling the visitor which it was would hand that distinction back.``
  [req]
  (def result (form/check e/Credentials (req :form)))
  (def check (when (empty? (result :errors))
               (auth/check-password (auth/user-store) (result :value))))
  (if-let [id (get check :identity)]
    (do
      (auth-http/login! req id)
      (ring/redirect "/"))
    (views/render-index (recent-articles)
                        {:sign-in (req :form)
                         :message "Those credentials do not match an account."})))

(defn sign-out
  "POST /sign-out — drop the identity and rotate the session id."
  [req]
  (auth-http/logout! req)
  (ring/redirect "/"))

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

(def own-article
  ``The three keys an owned route carries: somebody must be signed in,
  the policy must allow, and this is the row it decides about. Written
  once because it is one rule, not three.``
  {:void.auth/access :required
   :void.authz/policy :articles/own
   :void.authz/resource article-resource})

(router/defroutes :blog/routes
  (GET "/" home {:void.authz/policy :public})
  (POST "/register" register
        {:name :authors/register :void.authz/policy :public :void.db/txn true})
  (POST "/sign-in" sign-in {:name :session/create :void.authz/policy :public})
  (POST "/sign-out" sign-out {:name :session/delete :void.authz/policy :public})

  (POST "/articles" create-article
        {:name :articles/create
         :void.db/txn true
         :void.htmx/partial true
         # signed in, but no policy: any author may publish under their
         # own name, and there is no row to decide about yet
         :void.auth/access :required
         :void.authz/policy :authenticated})
  (GET "/articles/:id" show-article {:name :articles/show :void.authz/policy :public})
  (GET "/articles/:id/edit" edit-article (merge own-article {:name :articles/edit}))
  (POST "/articles/:id" update-article
        (merge own-article {:name :articles/update :void.db/txn true}))
  (DELETE "/articles/:id" delete-article
          (merge own-article {:name :articles/delete :void.db/txn true}))
  # comments stay open: a reader leaves a name, not an account. The
  # route says :public rather than saying nothing, because under
  # :default :deny saying nothing is a boot error — which is the point
  (POST "/articles/:id/comments" create-comment
        {:name :comments/create :void.db/txn true :void.htmx/partial true
         :void.authz/policy :public}))

# -- manifest ------------------------------------------------------------

(plugin/defplugin blog/app
  :doc "blog — a CRUD application on void/db, void/jobs and void/cache, with sign-in, a row-level policy and CSRF from wave 3."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"
             :void/db ">=0.0.1" :void/db-http ">=0.0.1"
             :void/cache ">=0.0.1" :void/jobs ">=0.0.1"
             :void/auth ">=0.0.1" :void/auth-http ">=0.0.1"
             :void/authz ">=0.0.1" :void/authz-http ">=0.0.1"
             :void/security ">=0.0.1"})
