### The jobs dashboard.
###
### Four claims. The section is a projection of the eight functions
### `:void/jobs-backend` already answers — the depth table is `counts`,
### the listing is `list`, the actions are `retry!`, `remove!` and
### `clear!` — so nothing here mocks a backend: the in-process one runs
### a real job into the dead letter queue and the pages read what it
### stored. Retry is refused on anything but a dead record, because
### reviving one a worker holds would run it twice. A bulk with no
### state is refused, because "everything" would include the records
### being run right now. And the two actions are ordinary admin actions
### under ordinary policies: a `defpolicy` named `:admin.jobs/discard`
### is the whole of taking Discard away, with no change to a route.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/jobs :as jobs)
(import void/admin :as admin)
(import void/authz :as authz)

# :fatal, not :error — the job below is *supposed* to die, and the
# worker says so at :error every time this suite runs
(log/set-level! nil :fatal)

(jobs/defjob boom
  "A job that always fails, so that the dead letter queue has
  something in it that got there the way records really do."
  {:queue :mail :max-attempts 1}
  []
  (error "the mail server said no"))

(jobs/defjob quiet
  "A job that works, so the depth table has a second queue in it."
  {:queue :default :max-attempts 1}
  []
  :ok)

(authz/defpolicy :staff "Everybody, in this test." [_] true)

(var discard-allowed
  "Flipped near the end: narrowing an action of the section is a
  policy of that name, and nothing else."
  true)

(authz/defpolicy :admin.jobs/discard
  "Declared here, so the plugin's default-allowing one is not
  registered — which is the whole mechanism under test."
  [_]
  (or discard-allowed "not today"))

(def core-plugins
  # void/db and a driver because void/admin declares them: the section
  # itself touches no database — a queue is not an entity — and the
  # pool is deliberately not in :only, which proves it
  ["void/http/init" "void/html/init" "void/htmx/init"
   "void/db/init" "void/db-sqlite/init" "void/db/http"
   "void/authz/init" "void/authz/http" "void/admin/init"
   "void/jobs/init" "void/admin/jobs"])

(defn- config [&opt admin-extra]
  {:env @{}
   :cli {:http {:port 0}
         :db-sqlite {:path ":memory:"}
         :jobs {:queues {:mail {:concurrency 1}}}
         :admin (merge {:access :staff} (or admin-extra {}))}})

(defn- start [&opt admin-extra]
  (test/start! {:plugins core-plugins
                :profile :test
                :config (config admin-extra)
                :only [:http/kernel :authz/registry :jobs/queue]}))

(defn- dead-id
  "Run the failing job into the dead letter queue and hand back its
  id — a real record, settled by the real runtime."
  []
  (def rec (jobs/enqueue :boom))
  (jobs/drain!)
  (assert (= :dead (get (jobs/fetch (rec :id)) :state))
          "a job out of attempts is dead — the fixture the pages are about")
  (rec :id))

(def boot (start))

(defer (test/stop! boot)
  (def c (test/client boot))
  (defn GET [uri] (test/inject c {:uri uri}))
  (defn POST [uri &opt form]
    (test/inject c {:method :post :uri uri :form (or form {})}))

  (jobs/enqueue :quiet)
  (jobs/drain!)
  # a pending record whose slot is ten minutes away — the queue is not
  # stuck, and the listing has to say which of the two it is
  (jobs/enqueue-in 600 :quiet)
  (def id (dead-id))

  # -- the section -------------------------------------------------------

  (def index (GET "/admin/jobs"))
  (assert (= 200 (index :status)) (string "the section: " (index :status)))
  (def page (test/text index))
  (assert (string/find `href="/admin/jobs"` page)
          "the navigation names the section — a :void.admin/menu :path resolved against [:admin :prefix]")
  (assert (string/find "mail" page) "the depth table has a row per queue")
  (assert (string/find "default" page))
  (assert (string/find "dead" page) "and a column per state")
  (assert (string/find "dead letter queue" page)
          "a dead record is said out loud, not left as a number in a table")
  (assert (string/find "in 10m" page)
          "a pending record with a slot ahead of it reads as delayed, not as stuck")

  # the fragment half of the same URL, on the same route
  (def frag (test/inject c {:uri "/admin/jobs" :headers {"hx-request" "true" "hx-request-type" "partial"}}))
  (assert (= 200 (frag :status)))
  (assert (not (string/find "<html" (test/text frag)))
          "a partial htmx request gets the body and no frame")
  (assert (string/find `id="admin-jobs"` (test/text frag)))

  # -- the dead letter queue ---------------------------------------------

  (def dlq (test/text (GET "/admin/jobs?state=dead")))
  (assert (string/find id dlq) "the filtered listing shows the record")
  (assert (string/find "Retry all" dlq) "and offers the two bulk actions")
  (assert (string/find "Discard all" dlq))

  (def pending-list (test/text (GET "/admin/jobs?state=pending")))
  (assert (not (string/find "Retry all" pending-list))
          "retry is offered on the dead letter queue and nowhere else")

  # -- one record --------------------------------------------------------

  (def one (GET (string "/admin/jobs/" id)))
  (assert (= 200 (one :status)))
  (assert (string/find "the mail server said no" (test/text one))
          "the record page carries the failure that killed it")
  (assert (= 404 ((GET "/admin/jobs/nosuchid") :status)))

  # -- retry and discard, one record -------------------------------------

  (assert (= 303 ((POST (string "/admin/jobs/" id "/-/retry")) :status)))
  (assert (= :pending (get (jobs/fetch id) :state))
          "retry puts a dead record back in the queue")

  (def again (POST (string "/admin/jobs/" id "/-/retry")))
  (assert (= 422 (again :status))
          "and refuses a record that is not dead — reviving a running one runs it twice")
  (assert (string/find "twice" (test/text again)) "saying why")

  # -- the bulk ----------------------------------------------------------

  (assert (= 422 ((GET "/admin/jobs/-/bulk/discard") :status))
          "a bulk with no state would mean every record, running ones included")
  (assert (= 422 ((GET "/admin/jobs/-/bulk/retry?state=pending") :status))
          "and a bulk retry of the not-dead is refused where a single one is")
  (assert (= 404 ((GET "/admin/jobs/-/bulk/nonsense?state=dead") :status)))

  # back to dead, and out again through the bulk
  (jobs/drain!)
  (assert (= :dead (get (jobs/fetch id) :state)))

  (def confirm (GET "/admin/jobs/-/bulk/retry?queue=mail&state=dead"))
  (assert (= 200 (confirm :status)))
  (assert (string/find ">1</span>" (test/text confirm))
          "the confirmation counts on the server, as every admin bulk does")

  (assert (= 303 ((POST "/admin/jobs/-/bulk/retry" {:queue "mail" :state "dead"}) :status)))
  (assert (= :pending (get (jobs/fetch id) :state)) "the bulk moved it")

  (assert (= 303 ((POST "/admin/jobs/-/bulk/discard" {:queue "mail" :state "pending"}) :status)))
  (assert (nil? (jobs/fetch id)) "and a discarded record is gone")

  # -- the policy is the ordinary one ------------------------------------

  (set discard-allowed false)
  (def refused (POST (string "/admin/jobs/" (dead-id) "/-/discard")))
  (assert (= 403 (refused :status))
          "a defpolicy named :admin.jobs/discard is the whole of taking Discard away")
  (assert (= 200 ((GET "/admin/jobs?state=dead") :status))
          "and it narrows that action only")
  (set discard-allowed true))

# -- the section knows where the admin is mounted ------------------------
#
# [:admin :prefix] is config and a contribution is a value frozen at
# load, which is why a `:void.admin/menu` item names a :path.

(def moved (start {:prefix "/back"}))

(defer (test/stop! moved)
  (def c (test/client moved))
  (def resp (test/inject c {:uri "/back/jobs"}))
  (assert (= 200 (resp :status)) (string "the section moves with the admin: " (resp :status)))
  (assert (string/find `href="/back/jobs"` (test/text resp))
          "and so does every link it draws")
  (assert (= 404 ((test/inject c {:uri "/admin/jobs"}) :status))
          "and it is not at the default prefix any more"))

(print "admin jobs-dashboard-test ok")
