### The operator's half: the desk, the raw body behind a signed URL,
### and replay (ROADMAP 6.6).
###
### Everything here is driven through the composition in ../main.janet
### the way a browser drives it (ADR-0017) — including the sign-in,
### because "who may read the deliveries" is the half of this that a
### mistake makes catastrophic rather than merely broken. A hub holds
### other people's payloads: a page that is one wrong config key away
### from public is exactly what the assertions below are for.
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/storage)
(import void/notify :as notify)
(import spork/sh)
(import ../main :as main)
(import ../src/modules/intake/intake.model :as model)
(import ../src/modules/intake/intake.repository :as deliveries)
(import ../src/modules/intake/intake.service :as intake)

(def secret "not-the-real-one-but-the-real-shape")

(def body
  "The bytes as they arrive — the same fixture the intake suite signs."
  (string (slurp "test/fixtures/github-push.json")))

(def delivery-id "cc000000-0000-4000-8000-000000000001")

(def tmp (string (or (os/getenv "TMPDIR") "/tmp") "/hub-ops-" (os/time)))
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
                               :rules [{:when {:event "push"} :to [:memory]}]
                               # the desk lets in exactly one address,
                               # which is the shape a deployment has
                               :operators ["ada@example.com"]}
                         # deliver on the calling fiber: this suite is
                         # about who may see what, and about replay
                         # sending again — the queue between projection
                         # and delivery is ../test/queue-test's claim
                         :notify {:queue false}
                         # registering asks the visitor to confirm
                         # their address, and a letter with a relative
                         # link is a letter with no link at all
                         :mail {:transport :memory
                                :base-url "http://localhost:8080"}
                         :auth {:scrypt {:ln 10}}
                         :crypto {:kdf {:in-thread false}}
                         :dev {:netrepl {:enabled false}
                               :watch {:enabled false}}}}}))

(defn- csrf-of [resp]
  (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`)))
                    (test/text resp))))

(defn- raw-body-href
  ``The temporary URL the deliveries page minted, out of the rendered
  page: whichever attribute order hiccup wrote, the link to the store
  is the one whose href starts with the serve prefix.``
  [resp]
  (when-let [tail (first (peg/match ~(* (thru `href="/storage/`) (<- (to `"`)))
                                    (test/text resp)))]
    # an href in HTML has its ampersands escaped; a URL does not
    (string "/storage/" (string/replace-all "&amp;" "&" tail))))

(defn- sign-up [client email]
  (def form (test/inject client {:uri "/register"}))
  (test/inject client {:uri "/register"
                       :headers {"x-csrf-token" (csrf-of form)}
                       :form {:email email :password "correct horse battery"}}))

(log/set-sinks! [(fn [_])])

# :authz/registry is in the list because that is the component that
# registers what plugins contributed to :void.authz/policy — the admin's
# own gate among them. A suite that leaves it out gets an application
# whose desk refuses with "unknown policy", which is a true answer to a
# question nobody asked
(test/with-http [c (merge opts {:only [:http/kernel :crypto/lib
                                       :auth/registry :authz/registry
                                       :storage/store :jobs/queue]})]
  (db/migrate-up! {:dir "db/migrations"})
  (notify/clear-outbox!)

  # -- one real delivery, received once ----------------------------------

  (def received
    (test/inject c {:uri "/in/github"
                    :method :post
                    :headers {"x-github-event" "push"
                              "x-github-delivery" delivery-id
                              "content-type" "application/json"
                              "x-hub-signature-256" (intake/signature-of secret body)}
                    :body body}))
  (assert (= 202 (received :status)))
  (def row (deliveries/by-delivery-id delivery-id))
  (assert row "the delivery is a row")

  # -- the front door is the queue ---------------------------------------

  (def anon (test/client (c :boot)))
  (def home (test/inject anon {:uri "/"}))
  (assert (= 302 (home :status)) "there is no page of this application's own")
  (assert (= "/admin/jobs" (get-in home [:headers "location"]))
          "/ is the jobs dashboard, reverse-routed from the name void/admin-jobs' page carries")

  # -- and it is shut ----------------------------------------------------

  (def stranger (test/inject anon {:uri "/admin/deliveries"}))
  (assert (= 302 (stranger :status))
          "[:admin :route-meta] :void.auth/access :required — the desk asks who is asking")
  (assert (string/has-prefix? "/login?" (get-in stranger [:headers "location"]))
          "and sends them to sign in rather than answering 403 with nothing to do about it")

  (def bob (test/client (c :boot)))
  (assert (= 302 ((sign-up bob "bob@example.com") :status)))
  (assert (= 403 ((test/inject bob {:uri "/admin/deliveries"}) :status))
          "signing in is not being an operator: registration here is open, and [:hub :operators] is the list")

  # -- the operator ------------------------------------------------------

  (assert (= 302 ((sign-up c "ada@example.com") :status)))

  (def jobs-page (test/inject c {:uri "/admin/jobs"}))
  (assert (= 200 (jobs-page :status)) "the main screen renders for an operator")

  (def page (test/inject c {:uri "/admin/deliveries"}))
  (assert (= 200 (page :status)))
  (assert (string/find "bondiano/void" (test/text page))
          "the list is the row the intake wrote, projected — no second model")
  (assert (string/find "raw body" (test/text page))
          "and the storage key is drawn as what an operator wants: a link to the bytes")

  # -- the bytes, and only through the link ------------------------------

  (def href (or (raw-body-href page) (error "no link to the store on the page")))
  (assert (string/find "exp=" href) "the link carries an expiry")
  (assert (string/find "sig=" href) "and a MAC over the key and that expiry (ADR-0039 §5)")

  (def bytes (test/inject c {:uri href}))
  (assert (= 200 (bytes :status)))
  (assert (= body (test/text bytes))
          "byte for byte what arrived — the signature was over these, so anything else would have lost the evidence")

  (def unsigned (test/inject c {:uri (first (string/split "?" href))}))
  (assert (= 403 (unsigned :status))
          "[:storage :serve :signed] — the prefix is private, and being signed in is not the authorization here")

  (def tampered
    (test/inject c {:uri (string/replace "sig=" "sig=x" href)}))
  (assert (= 403 (tampered :status))
          "an edited link is the same 403 as an expired one: which it was is nothing a client needs told")

  # -- replay ------------------------------------------------------------
  #
  # The bytes are already here, so the half worth running again is the
  # half with the decisions in it. Twice, because "as many times as it
  # takes" is the whole reason this exists (../ops.janet)

  (notify/clear-outbox!)
  (assert (= 1 (length (intake/replay! row)))
          "one rule covers this delivery, so replay is one notification")
  (intake/replay! row)
  (assert (= 2 (length (notify/outbox)))
          "and it sends every time it is asked to")
  (assert (= "bondiano/void — push by bondiano"
             (get (last (notify/outbox)) :title))
          "built from the bytes as they arrived, not from what the row remembers")
  (assert (= 1 (db/count model/Delivery))
          "replay routes again and never receives again: one delivery is one row")

  (assert (intake/find-delivery (string (row :id)))
          "an operator names a delivery by the row id...")
  (assert (intake/find-delivery delivery-id)
          "...or by the id the sender showed them")

  # -- the command starts what a replay needs ----------------------------
  #
  # `void hub replay` is a command, and a command starts what it named
  # in :needs and nothing else (../ops.janet's whole argument). The
  # bytes are in the store, so the store is in the list — asserted here
  # rather than found out on a machine where the row exists and the
  # blob is somewhere else
  (def commands (get-in boot [:extensions :void.core/cli :contributions] []))
  (def replay (first (map |(get $ :value)
                          (filter |(= :hub/replay (get-in $ [:value :name]))
                                  commands))))
  (assert replay "void hub replay is contributed")
  (each need [:db/pool :storage/store :jobs/queue]
    (assert (index-of need (get replay :needs []))
            (string "and it starts " need))))

(sh/rm tmp)
(log/set-sinks! nil)
(print "hub ops-test ok")
