### blog/jobs — the work that must not happen on the request path.
###
### The comment counter on `articles` is denormalized, so something has
### to keep it true. In void that something is a job, not an entity
### callback (ADR-0009): posting a comment enqueues `recount-comments`,
### the worker recomputes the count in a transaction and drops the
### cached index page. The queue lives in the database
### (:void/jobs-backend {:impl :jobs/db}), so it is the same
### transactional store as the data — and the same code on sqlite and
### on Postgres.
(import void/core/log :as log)
(import void/db :as db)
(import void/cache :as cache)
(import void/jobs :as jobs)
(import ./entities :as e)

(def index-cache-key
  "The one cached read in this application — the article list."
  "articles:index")

(defn recount!
  "Recompute one article's comment counter. Returns the new count."
  [article-id]
  (db/with-tx
    (def n (db/count e/Comment {:where [:= :article-id article-id]}))
    (db/update! e/Article article-id {:comment-count n})
    n))

(jobs/defjob recount-comments
  ``Bring one article's comment counter back in line with the
  comments table, then invalidate the cached index. :unique :args
  collapses a burst of comments on the same article into one run.``
  {:queue :maintenance :max-attempts 5 :unique :args}
  [article-id]
  (def n (recount! article-id))
  (cache/forget index-cache-key)
  (log/info "recounted comments" :ns "blog.jobs" :article article-id :comments n)
  n)

(jobs/defjob recount-all
  "Recount every article — the self-healing pass behind the schedule."
  {:queue :maintenance}
  []
  (def ids (map |($ :id) (db/query e/Article {:order-by [[:id :asc]]})))
  (each id ids (recount! id))
  (cache/forget index-cache-key)
  (log/info "recounted every article" :ns "blog.jobs" :articles (length ids))
  (length ids))

(jobs/defschedule nightly-recount
  "0 3 * * *"
  :recount-all)
