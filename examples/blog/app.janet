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
### Wave 3.5 added a second way in and no template for it: the "mail me a
### link" form posts to `request-link`, which calls `auth/challenge!` and
### stops there — the letter, its URL and its one-time code belong to
### `void/mail-auth`.
###
### The application's posture is `[:authz :default :deny]`
### (config/default.janet), so every route below names a policy —
### `:public` where it means it. A route that forgets one does not
### serve traffic and then get audited: it fails the boot.
###
### Wave 3.6 added an audit trail and touched the handlers three
### times, in the only way an audit trail should touch them: three
### `audit/record-tx!` calls that publish a *fact* into the transaction
### that made it. Nothing here writes an audit row, knows where one
### goes or knows that ./audit exists — that file subscribes to the bus
### and is deletable.
###
### The page-wave took the three shapes every handler here was written
### in and moved them into the framework: `:void.db/load` on the route
### is the whole of read-the-row-or-404 (and `:void.authz/resource`
### reads `(req :void.db/row)` instead of querying again), `form/submit`
### is the whole of check-then-either, `htmx/redirect-back` is the
### whole of after-a-write-which-client, and `html/flash!` is the
### sentence the next page says about it.
###
### Handlers are registered as symbols, so a redefinition in the repl — or
### a save with `void dev` running — is live.
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/router :as router)
(import void/http/ring :as ring)
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
(import ./audit :as audit)

# -- who is asking -------------------------------------------------------

(defn current-author-id
  ``The id of the signed-in author, or nil. The subject is
  `"author:42"` — `[:auth-db :users :subject-kind]` is the `author`
  half — so this is the one place the application unpacks it.``
  []
  (when-let [id (auth/current-user)]
    (scan-number (last (auth/subject-of (id :subject))))))

(defn subject-string
  "The signed-in subject as it goes into the audit trail (`author:42`),
  or nil for a visitor."
  []
  (when-let [id (auth/current-user)] (id :subject)))

(defn article-resource
  ``What the policy on the edit routes decides about: the row itself.
  Route metadata carries a function rather than a symbol, because a
  route entry does not keep the environment of the module that
  declared it — and the row is already on the request, because
  `:void.db/load` on the route put it there before authz runs; the
  second query this used to make is the load the route had already
  done.``
  [req]
  (req :void.db/row))

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
.``
  []
  (cache/remember blog-jobs/index-cache-key {:ttl 60}
    (fn load-index []
      (log/debug "index cache miss" :ns "blog.app")
      (db/query e/Article {:order-by [[:created-at :desc] [:id :desc]]
                           :limit 50
                           :preload [:author]}))))

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
  (form/submit e/NewArticle (req :form)
    {:ok (fn [v]
           (def created
             (db/insert! e/Article {:author-id (current-author-id)
                                    :title (v :title)
                                    :body (v :body)
                                    :comment-count 0
                                    :created-at (e/now)}))
           (audit/record-tx! :article/published (subject-string)
                             {:article (created :id) :title (v :title)})
           (invalidate-index!)
           (views/render-index (recent-articles) {}))
     :invalid (fn [values errors]
                (views/render-index (recent-articles) {:values values
                                                       :errors errors}))}))

# -- signing in ----------------------------------------------------------

(defn register
  ``POST /register — an author with a password.

  `auth/hash-password` produces a PHC string: the algorithm and its
  cost travel inside the value, so raising the cost later is a config
  change rather than a migration nobody can write. The sign-in that
  follows goes through the ordinary password path rather than trusting
  what was just inserted.``
  [req]
  (form/submit e/Registration (req :form)
    {:ok (fn [v]
           (if (db/one e/Author {:where [:= :email (v :email)]})
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
     :invalid (fn [values errors]
                (views/render-index (recent-articles) {:register values
                                                       :register-errors errors}))}))

(defn sign-in
  ``POST /sign-in — the password path, and nothing else.

  Whatever went wrong, the page says the same thing: `check-password`
  distinguishes an unknown address from a wrong password and spends
  the same time on both (it hashes even when there is no user), and
  telling the visitor which it was would hand that distinction back.``
  [req]
  (defn refused [values]
    (views/render-index (recent-articles)
                        {:sign-in values
                         :message "Those credentials do not match an account."}))
  (form/submit e/Credentials (req :form)
    {:ok (fn [v]
           (if-let [id (get (auth/check-password (auth/user-store) v) :identity)]
             (do
               (auth-http/login! req id)
               (ring/redirect "/"))
             (refused (req :form))))
     :invalid (fn [values _] (refused values))}))

(defn request-link
  ``POST /sign-in/magic — mail a one-time sign-in link.

  The application issues the challenge and says nothing else about
  it: `auth/challenge!` mints a single-use code, stores its digest and
  hands it to the deliverers, and `void/mail-auth` turns that into a
  letter. Which is why this handler contains no template, no URL and no
  token — those belong to the plugin that delivers.

  **The answer is the same whether or not the address has an
  account.** A page that said "no such account" would be a way to ask
  this blog who its authors are, one address at a time — the same
  reasoning that makes `check-password` spend its 25 ms on an unknown
  login.``
  [req]
  (form/submit e/MagicLink (req :form)
    {:ok (fn [v]
           (when-let [author (db/one e/Author {:where [:= :email (v :email)]})]
             (auth/challenge! (string "author:" (author :id))
                              {:to (author :email)
                               # the claim the page greets them with, so
                               # redeeming the link needs no second query
                               :claims {:name (author :name)}}))
           (views/render-index (recent-articles)
                               {:message "If that address has an account, a sign-in link is on its way."}))
     :invalid (fn [values _]
                (views/render-index (recent-articles)
                                    {:magic-link values
                                     :message "That does not look like an email address."}))}))

(defn magic-link
  ``GET /auth/magic?h=&c= — the link from the letter.

  `redeem!` takes the challenge out of the store before it checks the
  code, so a link works once and a wrong one is spent: the visitor asks
  for another, which costs them a click and an attacker a full guess of
  256 bits per try.``
  [req]
  (def query (or (req :query) {}))
  (if-let [id (auth/redeem! (get query "h") (get query "c"))]
    (do
      (auth-http/login! req id)
      (ring/redirect "/"))
    (views/render-index (recent-articles)
                        {:message "That sign-in link has expired or has already been used."})))

(defn sign-out
  "POST /sign-out — drop the identity and rotate the session id."
  [req]
  (auth-http/logout! req)
  (ring/redirect "/"))

(defn show-article
  ``GET /articles/:id — the article, its author and its comments. The
  route's `:void.db/load` is the whole of read-the-row-or-404: the id
  is coerced through the entity's key schema, a malformed one never
  reaches the database, and the row arrives preloaded and before the
  handler runs.``
  [req]
  (html/page (views/article-view (req :void.db/row)) {:layout views/layout}))

(defn edit-article
  "GET /articles/:id/edit — the form over the columns save! may touch."
  [req]
  (html/page (views/edit-view (req :void.db/row)) {:layout views/layout}))

(defn update-article
  ``POST /articles/:id — dirty tracking: the instance is changed in
  place and `save!` writes a partial UPDATE of exactly the columns
  that differ from the snapshot it was loaded with, or no statement at
  all when nothing did. The article is the row `:void.db/load` put on
  the request — the same row the policy decided about.``
  [req]
  (def article (req :void.db/row))
  (form/submit e/EditArticle (req :form)
    {:ok (fn [v]
           (merge-into article v)
           (def changed (db/changes article))
           (db/save! article)
           (unless (empty? changed)
             (log/info "article updated" :ns "blog.app"
                       :article (article :id) :columns (sorted (keys changed)))
             (audit/record-tx! :article/updated (subject-string)
                               {:article (article :id)
                                :columns (map string (sorted (keys changed)))})
             (invalidate-index!))
           (html/flash! req :ok "Saved.")
           (ring/redirect (string "/articles/" (article :id))))
     :invalid (fn [values errors]
                (html/page (views/edit-view article values errors)
                           {:layout views/layout}))}))

(defn delete-article
  "DELETE /articles/:id — the comments go with it (ON DELETE CASCADE)."
  [req]
  (def article (req :void.db/row))
  (db/delete! e/Article (article :id))
  (audit/record-tx! :article/deleted (subject-string)
                    {:article (article :id) :title (article :title)})
  (invalidate-index!)
  (html/flash! req :ok (string "Deleted “" (article :title) "”."))
  (htmx/redirect-back req "/"))

(defn create-comment
  ``POST /articles/:id/comments — the write is synchronous, the
  bookkeeping is not: the counter on `articles` is recomputed by
  :recount-comments on the maintenance queue, which also drops the
  cached index. :unique :args means a burst of comments on one article
  is one recount. The page answers with the article re-read after the
  insert — the row `:void.db/load` brought in was current before the
  comment, and the page has to show it after.``
  [req]
  (def article (req :void.db/row))
  (form/submit e/NewComment (req :form)
    {:ok (fn [v]
           (db/insert! e/Comment (merge v
                                        {:article-id (article :id)
                                         :created-at (e/now)}))
           (jobs/enqueue :recount-comments (article :id))
           # the fact, into the transaction that made it (:void.db/txn true
           # on the route): the trail cannot say a comment was posted that
           # was not, and cannot miss one that was
           (audit/record-tx! :comment/posted nil
                             {:article (article :id)
                              :author (v :author-name)})
           (html/page
             (views/article-view
               (db/find e/Article (article :id) {:preload [:author :comments]}))
             {:layout views/layout}))
     :invalid (fn [values errors]
                (html/page (views/article-view article values errors)
                           {:layout views/layout}))}))

# -- routes --------------------------------------------------------------

(def own-article
  ``The keys an owned route carries: somebody must be signed in, the
  policy must allow, this is the row it decides about, and — because
  the loader runs before authz — the row is the one the middleware
  loaded rather than a second query. Written once because it is one
  rule, not four.``
  {:void.auth/access :required
   :void.authz/policy :articles/own
   :void.authz/resource article-resource
   :void.db/load {:entity e/Article}})

(router/defroutes :blog/routes
  (GET "/" home {:void.authz/policy :public})
  # no :void.db/txn: a route transaction would hold the writer through
  # the password KDF; the register is one INSERT, and the duplicate
  # address is the email column's unique index's to refuse
  (POST "/register" register
        {:name :authors/register :void.authz/policy :public})
  (POST "/sign-in" sign-in {:name :session/create :void.authz/policy :public})
  (POST "/sign-in/magic" request-link
        {:name :session/request-link :void.authz/policy :public})
  # where the letter's link points ([:mail-auth :link-path]). A GET
  # that signs somebody in is safe here for the reason a password POST
  # is not: the credential is in the URL the visitor was mailed, not in
  # a cookie a third-party page could make the browser send
  (GET "/auth/magic" magic-link
       {:name :session/magic-link :void.authz/policy :public})
  (POST "/sign-out" sign-out {:name :session/delete :void.authz/policy :public})

  (POST "/articles" create-article
        {:name :articles/create
         :void.db/txn true
         :void.htmx/partial true
         # signed in, but no policy: any author may publish under their
         # own name, and there is no row to decide about yet
         :void.auth/access :required
         :void.authz/policy :authenticated})
  (GET "/articles/:id" show-article
       {:name :articles/show :void.authz/policy :public
        # the row, its author and its comments, before the handler —
        # read-the-row-or-404 is the route's to say
        :void.db/load {:entity e/Article :preload [:author :comments]}})
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
         :void.authz/policy :public
         # preloaded because the invalid branch re-renders the article
         # from this row, author and comments and all
         :void.db/load {:entity e/Article :preload [:author :comments]}}))

# -- manifest ------------------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   # after the bus started its consumers (:bus/consume is 800): the
   # first denial should have somewhere to go
   :phase 900
   :name :blog/audit
   :doc "Turn void/authz's refusals into bus messages (see ./audit)"
   :fn audit/install!})

(plugin/defplugin blog/app
  :doc "blog — a CRUD application on void/db, void/jobs and void/cache, with sign-in, a row-level policy and CSRF from wave 3, and an audit trail that rides the transactional outbox from 3.6."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1" :void/htmx ">=0.0.1"
             :void/db ">=0.0.1" :void/db-http ">=0.0.1"
             :void/cache ">=0.0.1" :void/jobs ">=0.0.1"
             :void/auth ">=0.0.1" :void/auth-http ">=0.0.1"
             :void/authz ">=0.0.1" :void/authz-http ">=0.0.1"
             :void/security ">=0.0.1"
             :void/mail ">=0.0.1" :void/mail-auth ">=0.0.1"
             # 3.6: the audit trail is a bus consumer, and the facts it
             # records ride the transactional outbox
             :void/bus ">=0.0.1" :void/bus-db ">=0.0.1"})
