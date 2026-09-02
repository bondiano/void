### The receiving end, driven the way GitHub drives it (ADR-0017):
### test/inject puts a request through the whole chain — routing,
### middleware, the handler, the store, the row — without opening a
### socket, so what passes here is what a delivery gets.
###
### The body is a **file**, not a literal, and it is shaped like the
### thing GitHub actually sends: the signature is over exact bytes, and
### a fixture that a test re-encodes is a fixture that proves the test's
### own encoder rather than the sender's.
(import void/core/log :as log)
(import void/test :as test)
(import void/http :as http)
(import void/db :as db)
(import void/storage)
(import void/notify :as notify)
(import void/crypto :as crypto)
(import spork/json)
(import spork/sh)
(import ../main :as main)
(import ../intake :as intake)

(def secret "not-the-real-one-but-the-real-shape")

(def body
  ``The bytes as they arrive — read once, signed as read, never
  re-encoded. `string` because `slurp` hands back a buffer, and a
  fixture that anything could append to is not a fixture.``
  (string (slurp "test/fixtures/github-push.json")))

(def tmp (string (or (os/getenv "TMPDIR") "/tmp") "/hub-intake-" (os/time)))
(def sqlite-path (string tmp "/hub.sqlite3"))

(sh/rm tmp)
(os/mkdir tmp)

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{}
                   :cli {:http {:port 0}
                         :db {:migrations {:dir "db/migrations"}}
                         :db-sqlite {:path sqlite-path}
                         :storage {:local {:root (string tmp "/storage")}}
                         # the one source this suite receives from, and
                         # one rule over it: a push to this repository
                         # goes to the channel a test can read
                         :hub {:sources {:github {:signing-secret secret}}
                               :rules [{:when {:event "push"
                                               :repo "bondiano/void"}
                                        :to [:memory]}]}
                         # deliver on the calling fiber: that a queue
                         # fits between projection and delivery is
                         # void/notify-jobs' claim and its own suite's
                         :notify {:queue false}
                         :mail {:transport :memory}
                         :auth {:scrypt {:ln 10}}
                         :crypto {:kdf {:in-thread false}}
                         :dev {:netrepl {:enabled false}
                               :watch {:enabled false}}}}}))

(defn- delivery
  ``One delivery as GitHub sends it: the event, the id it retries under,
  and a signature over the bytes. `:headers` overrides one of them,
  `:unsigned` sends none at all — and it has to be its own option rather
  than a nil override, because putting nil into a table removes the key
  and the delivery would have gone out correctly signed.``
  [id &opt overrides]
  (default overrides {})
  (def payload (get overrides :body body))
  (def signed
    (if (get overrides :unsigned)
      {}
      {"x-hub-signature-256" (intake/signature-of secret payload)}))
  (merge {:uri (get overrides :uri "/in/github")
          :method :post
          :headers (merge {"x-github-event" "push"
                           "x-github-delivery" id
                           "content-type" "application/json"}
                          signed
                          (get overrides :headers {}))
          :body payload}
         (get overrides :request {})))

(defn- json-of [resp]
  (json/decode (test/text resp) true))

(log/set-sinks! [(fn [_])])

(test/with-http [c (merge opts {:only [:http/kernel :crypto/lib
                                       :auth/registry :storage/store]})]
  (db/migrate-up! {:dir "db/migrations"})

  # -- the delivery that checks out --------------------------------------
  (def ok (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000001")))
  (assert (= 202 (ok :status))
          "accepted, because where this event goes is decided after the answer")
  (assert (= "received" ((json-of ok) :status)))

  (def row (intake/find-by-delivery-id "ce4b1f00-0000-4000-8000-000000000001"))
  (assert row "the delivery is a row")
  (assert (= "push" (row :event)))
  (assert (= "bondiano/void" (row :repo))
          "what the payload was about is read out of it, once")
  (assert (= "bondiano" (row :sender)))
  (assert (= (length body) (row :size)))

  # the bytes are kept **verbatim**: this is the assertion the whole
  # arrangement exists for — a signature is over bytes, so a store that
  # returns anything but the same bytes has lost the evidence
  (assert (= body (string (storage/fetch (row :body-key))))
          "the raw body comes back out of the store byte for byte")
  (assert (string/has-prefix? "github/" (row :body-key))
          "and it is filed under the source that sent it")

  # -- and what the rule did with it -------------------------------------
  #
  # the routing decision is made on the request fiber, where the request
  # still is (ADR-0040): by the time the sender has its 202, the
  # notification has been projected
  (def notified (last (notify/outbox)))
  (assert notified "a delivery a rule covers is a notification")
  (assert (= "bondiano/void — push by bondiano" (notified :title)))
  (assert (= "refs/heads/main · 1 commit · feat: hub — the receiving end"
             (notified :body)))
  (assert (= "ce4b1f00-0000-4000-8000-000000000001"
             (get-in notified [:data :delivery]))
          "and it carries the delivery it came from, so a message traces back")

  # -- the retry ---------------------------------------------------------
  #
  # GitHub redelivers, and a redelivery carries the same id. Accepting
  # it twice would mean two rows, two blobs and — later — two messages
  (def again (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000001")))
  (assert (= 202 (again :status)) "a retry is not an error")
  (assert (= "duplicate" ((json-of again) :status)))
  (assert (= 1 (db/count intake/Delivery
                         {:where [:= :delivery-id
                                  "ce4b1f00-0000-4000-8000-000000000001"]}))
          "and it is still one delivery")

  # -- a delivery no rule covers -----------------------------------------
  #
  # normal, and not a failure: the hub received it, kept it, and had
  # nowhere it was asked to send it
  (def before (length (notify/outbox)))
  (def unrouted
    (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000006"
                             {:headers {"x-github-event" "issues"}})))
  (assert (= 202 (unrouted :status)))
  (assert (intake/find-by-delivery-id "ce4b1f00-0000-4000-8000-000000000006")
          "it is still a delivery, kept like every other")
  (assert (= before (length (notify/outbox)))
          "and nothing went out, because no rule said to")

  # -- the signature that does not check out -----------------------------
  (def forged
    (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000002"
                             {:headers {"x-hub-signature-256"
                                        (intake/signature-of "another-secret" body)}})))
  (assert (= 401 (forged :status)))
  (assert (nil? (intake/find-by-delivery-id "ce4b1f00-0000-4000-8000-000000000002"))
          "nothing is written before the signature is checked")

  # a body changed after signing is the same refusal — this is the case
  # the raw bytes exist for, and it is why nothing re-encodes them
  (def tampered
    (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000003"
                             {:body (string/replace "bondiano/void" "attacker/void" body)
                              :headers {"x-hub-signature-256"
                                        (intake/signature-of secret body)}})))
  (assert (= 401 (tampered :status)))

  (def unsigned
    (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000004"
                             {:unsigned true})))
  (assert (= 401 (unsigned :status)) "no signature is a wrong signature")

  # -- the source nobody configured --------------------------------------
  (def unknown (test/inject c (delivery "ce4b1f00-0000-4000-8000-000000000005"
                                        {:uri "/in/gitlab"})))
  (assert (= 404 (unknown :status))
          "an endpoint nobody set up refuses before it hashes anything")

  # -- an id a storage key cannot hold -----------------------------------
  (def wild (test/inject c (delivery "../../etc/passwd")))
  (assert (= 400 (wild :status))
          "the key is data, so the data is checked rather than laundered")
  (assert (nil? (intake/find-by-delivery-id "../../etc/passwd"))
          "and nothing was written under it")
  (assert (not (storage/valid-key? "github/../../etc/passwd.json"))
          "the store would have refused that key too — this refuses earlier, with a status")

  # -- the one route that reads more than a form -------------------------
  #
  # `[:http :max-body]` is 64 KiB and is what a route that declares
  # nothing gets; the intake route declares GitHub's 25 MiB on itself.
  # `:restrict` binds a route to the *metadata* layers above it, and
  # this source declares none — asserted here because the shape used to
  # be the other way round, and the inverse looks identical until you
  # read what the application means (README, ROADMAP 6.6)
  (assert (= 26214400 (get-in (http/explain-route "/in/github" :post)
                              [:meta :void.http/max-body]))
          "the route that receives a delivery says what a delivery weighs")
  (assert (nil? (get-in (http/explain-route "/register" :get)
                        [:meta :void.http/max-body]))
          "and a page says nothing, so it gets the application's 64 KiB"))

(sh/rm tmp)
(log/set-sinks! nil)
(print "hub intake-test ok")
