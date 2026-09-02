### The half of the composition the other suites deliberately switch
### off: with void/notify-jobs composed, a notification is **projected**
### on the request fiber and **delivered** on a worker (ADR-0040 §3).
###
### What that buys is the whole argument for two functions instead of
### one, and it is asserted here: after the sender has its 202 there is
### a job and no message, and after the queue runs there is a message —
### built from the value the request projected, not from the arguments
### that would have built it.
###
### A job **per channel**, not per notification: they fail differently
### and retry differently, and a failed telegram must not send a second
### copy of everything that went out beside it.
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/jobs)
(import void/notify :as notify)
(import spork/sh)
(import ../main :as main)
(import ../src/modules/intake/intake.repository :as deliveries)
(import ../src/modules/intake/intake.service :as intake)

(def secret "not-the-real-one-but-the-real-shape")
(def body (string (slurp "test/fixtures/github-push.json")))

(def tmp (string (or (os/getenv "TMPDIR") "/tmp") "/hub-queue-" (os/time)))
(sh/rm tmp)
(os/mkdir tmp)

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{}
                   :cli {:http {:port 0}
                         :db {:migrations {:dir "db/migrations"}}
                         :db-sqlite {:path (string tmp "/hub.sqlite3")}
                         :storage {:local {:root (string tmp "/storage")}}
                         :hub {:sources {:github {:signing-secret secret}}
                               # two rules over one delivery, so "a job
                               # per channel" is a number this suite can
                               # count rather than a sentence it repeats
                               :rules [{:when {:event "push"} :to [:memory]}
                                       {:when {:repo "bondiano/void"} :to [:log]}]}
                         # no :notify :queue here on purpose: :auto means
                         # "queued when void/notify-jobs is composed",
                         # and this suite is about what that default does
                         :mail {:transport :memory}
                         :auth {:scrypt {:ln 10}}
                         :crypto {:kdf {:in-thread false}}
                         :dev {:netrepl {:enabled false}
                               :watch {:enabled false}}}}}))

(defn- delivery [id]
  {:uri "/in/github"
   :method :post
   :headers {"x-github-event" "push"
             "x-github-delivery" id
             "content-type" "application/json"
             "x-hub-signature-256" (intake/signature-of secret body)}
   :body body})

(defn- pending
  ``How much work the queue still owes, across every queue in it. The
  states are void/jobs' own (`record-live-states`) rather than a list
  copied into this file, which is the difference between a suite that
  follows the contract and one that has an opinion about it.``
  []
  (def live jobs/record-live-states)
  (var total 0)
  (eachp [_ states] (jobs/counts)
    (eachp [state n] states
      (when (index-of state live) (+= total n))))
  total)

(log/set-sinks! [(fn [_])])

(test/with-http [c (merge opts {:only [:http/kernel :crypto/lib :auth/registry
                                       :storage/store :jobs/queue]})]
  (db/migrate-up! {:dir "db/migrations"})
  (notify/clear-outbox!)

  (assert (notify/queued?)
          "notify-jobs is composed, so [:notify :queue] :auto means queued")

  (def before (pending))
  (def resp (test/inject c (delivery "aa000000-0000-4000-8000-000000000001")))
  (assert (= 202 (resp :status)))

  # the delivery is kept and the sender is answered — and nothing has
  # been delivered anywhere yet
  (assert (deliveries/by-delivery-id "aa000000-0000-4000-8000-000000000001"))
  (assert (empty? (notify/outbox))
          "delivery happens on a worker, not on the request")
  (assert (= 2 (- (pending) before))
          "two rules, two channels, two jobs — a job per channel (ADR-0040 §3)")

  # now be the worker. The queue is named — void/notify-jobs puts its
  # jobs on :notify — and a drain claims from the queues it is told
  # about, the same way `void jobs work --queue notify` does
  (jobs/drain! {:queues [:notify]})

  (assert (= 1 (length (notify/outbox)))
          "and the queue delivered the projection the request had made")
  (def sent (first (notify/outbox)))
  (assert (= "bondiano/void — push by bondiano" (sent :title))
          "the same value the request meant, not one rebuilt on the worker")
  (assert (= "aa000000-0000-4000-8000-000000000001" (get-in sent [:data :delivery])))
  (assert (zero? (- (pending) before)) "and the queue is empty again"))

(sh/rm tmp)
(log/set-sinks! nil)
(print "hub queue-test ok")
