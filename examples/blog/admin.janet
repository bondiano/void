### blog/admin — the back office, declared.
###
### This whole file is declarations. There are no handlers, no
### templates and no routes: `void/admin` projects the registry into
### routes when the table is built, and `void/admin-mcp` — if the
### composition has it — projects the same registry into MCP tools for
### an agent. Adding a field to ./entities puts it in the list, in the
### form, and in the tool, in one edit.
###
### Two things worth reading for what they do *not* say.
###
### **Scoping is one function.** `:scope` narrows the query and the
### count with the same clause, so an author's list pages over their own
### articles and says how many of them there are. Behind it, the edit and
### delete actions still pass `:articles/own` — the row-level policy this
### application already had, for its own routes, reused by name (the two
### echelons).
###
### **The trail is not new.** The admin owns no table:
### it announces `:void.admin/changed` and somebody else decides
### whether that survives the process. Here the somebody is ./audit,
### which has been writing this application's facts since wave 3.6 —
### so the admin's changes land in the same table, under the same
### correlation id, next to the changes the application's own routes
### made, and this file adds one function to make it so. The history
### tab is the other direction: `:void.admin/history` reads
### `audit/trail`, and no migration ships with any of it.

(import void/core/plugin :as plugin)
(import void/auth :as auth)
(import void/authz :as authz)
(import void/admin :as admin)
(import void/bus :as bus)
(import ./entities :as e)
(import ./audit :as audit)

# -- who is an operator --------------------------------------------------

(authz/defpolicy :blog/staff
  ``The gate of the admin. Anybody who signed in is staff here, which
  is a decision this example is entitled to make and a real deployment
  is not — narrowing it is editing this policy, and nothing else:
  neither the declarations below nor a single route mention it.``
  [ctx]
  (or (not (nil? (authz/attr ctx :subject/id)))
      "not signed in"))

(defn- current-author-id []
  (when-let [id (auth/current-user)]
    (scan-number (last (auth/subject-of (id :subject))))))

(defn- own-articles
  "An author's list is their own articles — the same narrowing the
  edit routes have enforced since wave 3, applied to the query instead
  of to one row, so the count on the page counts what the page shows."
  [_req]
  [:= :author-id (or (current-author-id) -1)])

# -- the declarations ----------------------------------------------------

(admin/defresource-admin articles e/Article
  :title "Articles"
  :list [:id :title :comment-count :created-at]
  :detail [:id :title :body :comment-count :created-at]
  :search [:title :body]
  :sortable [:id :title :created-at]
  :editable [:title]
  :form [:title :body]
  :order-by [[:id :desc]]
  :scope own-articles
  # `created_at` is NOT NULL and nobody types a timestamp; the author of a
  # row created here is whoever created it. Entities have no callbacks by
  # design, so the value comes from whoever writes the row — and the admin
  # is one of the writers
  :defaults {:created-at (fn [_req] (e/now))
             :author-id (fn [_req] (current-author-id))}
  # the comments of an article, edited on the article's page. The target
  # is declared below with :mount false — its fields and its policies
  # exist once, and the inline is guarded by the child's policies as well
  # as by this resource's :show
  :inlines {:comments {:style :table :fields [:author-name :body]}})

(admin/defresource-admin comments e/Comment
  :title "Comments"
  # a declaration without a section: it exists to be the target of the
  # inline above, and to be readable by an agent
  :mount false
  :list [:id :author-name :body :created-at]
  :form [:author-name :body]
  :defaults {:created-at (fn [_req] (e/now))})

(admin/defresource-admin authors e/Author
  :title "Authors"
  :list [:id :name :email]
  # the hash is a column, and it is a column *only* for the writes
  # (./entities says so) — so no projection names it: not the form,
  # and not the detail page either. Leaving :detail out would derive
  # it from the entity, and a derived projection is exactly how a
  # password hash ends up on a show page and in an agent's get tool.
  :detail [:id :name :email]
  :search [:name :email]
  :sortable [:id :name]
  # leaving the hash out of :form leaves it out of the tool an agent
  # gets, too
  :form [:name :email]
  :only [:index :show])

(admin/defresource-admin audit-events e/AuditEvent
  :title "Audit"
  :list [:id :at :topic :actor :detail]
  :search [:topic :actor :detail]
  :sortable [:id :at :topic]
  :filters [:topic]
  :order-by [[:id :desc]]
  # a trail nobody may edit from the page that displays it
  :only [:index :show])

# -- the trail takes the admin's changes, and gives back the history -----

(defn- record-change!
  ``Turn one `:void.admin/changed` announcement into a bus message.
  That is the entire integration: the admin does not know what a bus
  is, ./audit does not know what the admin is, and the trail gets the
  back office for free — with the message riding the same
  transactional outbox as everything else, because the admin's writing
  routes carry `:void.db/txn`.``
  [fact]
  (bus/publish-tx! (keyword "admin/" (fact :action))
                   {:actor (fact :subject)
                    :at (e/now)
                    :resource (string (fact :resource))
                    :id (fact :id)
                    :before (fact :before)
                    :after (fact :after)}))

(plugin/contribute! :void.core/hooks
  {:hook :void.admin/changed
   :name :blog/admin-audit
   :doc "Announce every admin change on the bus, so the trail this application already keeps records it"
   :fn record-change!})

(plugin/contribute! :void.admin/history
  {:name :blog/history
   :doc "The history tab, over the audit trail this application already writes"
   :fn (fn history [{:resource rname :id id}]
         (seq [row :in (audit/trail {:limit 20})
               :when (string/find (string "\"id\":" id) (or (row :detail) ""))
               :when (string/find (string (string rname)) (or (row :detail) (row :topic)))]
           {:at (row :at) :actor (row :actor) :detail (row :topic)}))})

(plugin/defplugin blog/admin
  :doc "The blog's back office: four declarations, no handlers and no templates. Every action is a route with the shut-by-default gate plus its own policy, an author's list is scoped to their own articles, comments are edited inline on the article, and every change is announced onto the bus the audit trail already reads."
  :version "0.1.0"
  :requires {:void/admin ">=0.0.1" :void/authz ">=0.0.1"
             :void/bus ">=0.0.1" :blog/app ">=0.1.0"})
