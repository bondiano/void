# The webhook channel. The receiver here is a void/http server, which
# is the only counterpart that can prove the bytes are a request
# somebody else's code could read — and the only one that can answer
# with the status codes the retry decision is made from.

(import ../test-support/paths)
(import spork/json)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/http/ring :as ring)
(import void/http/server :as server)
(import void/test :as test)
(import void/notify :as notify)
(import void/notify/webhook :as webhook)
(require "void/notify/webhook")

(log/set-level! "void" :error)

# -- the receiver --------------------------------------------------------

(def received @[])

(defn- receiver [req]
  (array/push received {:path (req :path)
                        :headers (req :headers)
                        :body (req :body)})
  (case (req :path)
    "/hook" (ring/text 200 "ok")
    "/mine" (ring/text 200 "ok")
    "/gone" (ring/text 404 "no such hook")
    "/later" (ring/text 429 "slow down")
    "/broken" (ring/text 503 "try again")
    (ring/not-found)))

(def inst (server/start {:handler receiver :port "0" :idle-timeout 2}))
(def endpoint (string "http://127.0.0.1:" (inst :port)))

(def plugins ["void/crypto/init" "void/notify/init" "void/notify/webhook"])

(defn- start [&opt extra]
  (test/start! {:plugins plugins
                :profile :test
                :config {:env @{}
                         :cli (merge {:log {:level :error}
                                      :notify-webhook {:url (string endpoint "/hook")
                                                       :signing-key "shhh"
                                                       # the receiver stands on loopback,
                                                       # which per-notification URLs may
                                                       # not reach by default — named, the
                                                       # way a deployment would name it
                                                       :allow-hosts ["127.0.0.1"]
                                                       # the configured endpoint's own
                                                       # credential (see the headers tests)
                                                       :headers {"authorization" "Bearer cfg-token"}}}
                                     (or extra {}))}}))

# -- the wire format is a pure projection --------------------------------

(def note (notify/normalize {:key :order/shipped
                             :title "Your order shipped"
                             :body "on its way"
                             :url "/orders/1042"
                             :data {:order 1042}
                             :to {:url (string endpoint "/hook")}}
                            [:webhook]
                            {:id "ntf_test" :at 1756400000}))

(def body (webhook/body-of note))
(def decoded (json/decode body true))
(assert (= "ntf_test" (decoded :id)))
(assert (= "order/shipped" (decoded :key))
        "the key is a string on the wire — a keyword is void's spelling, not JSON's")
(assert (= 1756400000 (decoded :at)))
(assert (= 1042 (get-in decoded [:data :order])))

# -- what a retry is for -------------------------------------------------

(assert (webhook/permanent? {:status 404}) "a wrong URL is not fixed by trying again")
(assert (webhook/permanent? {:status 401}) "and neither is a signature the receiver will not take")
(assert (not (webhook/permanent? {:status 429}))
        "429 says \"later\" in as many words")
(assert (not (webhook/permanent? {:status 408})))
(assert (not (webhook/permanent? {:status 503})))
(assert (not (webhook/permanent? {:message "connection reset"}))
        "and a connection that broke never got an answer at all")
(assert (webhook/permanent? {:blocked true})
        "a refused address is final too — the address does not get better with retries")

# -- where a notification may point a POST (the pure half) ---------------

(each addr ["127.0.0.1" "127.8.8.8" "10.1.2.3" "172.16.0.1" "172.31.255.255"
            "192.168.1.1" "169.254.169.254" "0.0.0.0"
            "::1" "::" "fe80::1" "fd00::1" "fc00::2" "::ffff:127.0.0.1" "::ffff:10.0.0.1"]
  (assert (webhook/private-address? addr)
          (string addr " is an address a webhook must not reach by default")))
(each addr ["8.8.8.8" "1.1.1.1" "172.32.0.1" "172.15.0.1" "198.51.100.7"
            "2606:4700::1" "::ffff:8.8.8.8"]
  (assert (not (webhook/private-address? addr))
          (string addr " is public")))
(assert (webhook/private-address? "not-an-address")
        "what cannot be judged is not sent to")

(assert (webhook/target-refusal "http://127.0.0.1:9/x" {})
        "a per-notification URL at loopback is refused by default — the SSRF the audit is about")
(assert (webhook/target-refusal "http://localhost:9/x" {})
        "through the resolver too: the name is resolved and the resolved address judged")
(assert (webhook/target-refusal "http://169.254.169.254/latest/meta-data" {})
        "the cloud metadata address above all")
(assert (nil? (webhook/target-refusal "http://127.0.0.1:9/x" {:allow-hosts ["127.0.0.1"]}))
        "an allow-listed host may be private")
(assert (nil? (webhook/target-refusal "http://10.0.0.8/x" {:allow-hosts ["10.0.0.0/8"]}))
        "an allow-hosts entry may be a CIDR")
(assert (webhook/target-refusal "http://10.1.0.8/x" {:allow-hosts ["10.0.0.0/16"]})
        "and an address outside it stays refused")
(assert (nil? (webhook/target-refusal "http://127.0.0.1:9/x" {:allow-private true}))
        "[:notify-webhook :allow-private] is the deliberate switch for delivering into one's own network")

# -- a signing key this process cannot sign with -------------------------
#
# First, and deliberately: libcrypto is opened once per process and
# stays open, so the only honest place to ask what happens without it
# is before any composition here has opened it.

(def [ok err]
  (protect (test/start! {:plugins ["void/notify/init" "void/notify/webhook"]
                         :profile :test
                         :config {:env @{}
                                  :cli {:log {:level :error}
                                        :notify-webhook {:url "http://example.invalid/hook"
                                                         :signing-key "shhh"}}}})))
(assert (not ok) "a configured signing key without void/crypto in the composition is a boot error")
(assert (string/find ":void/crypto" (string err))
        "naming the plugin, rather than leaving a signature nobody ever verifies")

# -- a booted channel ----------------------------------------------------

(def boot (start))

(defer (do (test/stop! boot) (server/stop inst))
  (array/clear received)

  (assert (deep= @[:webhook] (notify/active)))

  (def result (notify/send {:key :order/shipped
                            :title "Your order shipped"
                            :to {:email "ada@example.com"}}))
  (assert (= :sent (get-in result [:results 0 :status]))
          "with [:notify-webhook :url] configured every notification goes there — :to says nothing about it")
  (assert (= 200 (get-in result [:results 0 :receipt :status])))
  (assert (= 1 (length received)))

  (def req (first received))
  (assert (= "application/json" (get-in req [:headers "content-type"])))
  (assert (= (result :id) (get-in req [:headers "x-void-notification"])))
  (assert (= "order/shipped" (get-in req [:headers "x-void-event"])))
  (assert (= "Bearer cfg-token" (get-in req [:headers "authorization"]))
          "the configured endpoint gets the configured headers — they are its credential")

  # -- the signature is verifiable, and it is signed at delivery ---------

  (def sig (get-in req [:headers "x-void-signature"]))
  (assert sig "a configured secret arms the signature")
  (def parts (string/split "," sig))
  (def t (string/slice (first parts) 2))
  (def v1 (string/slice (last parts) 3))
  (assert (= v1 (crypto/hex (crypto/hmac-sha256 "shhh" (string t "." (req :body)))))
          "t=<unix>,v1=<hex hmac of t.body> — the shape a receiver has already implemented")
  (assert (>= (scan-number t) (get-in result [:at]))
          "and the timestamp is the delivery's, not the projection's: a MAC minted before a queue would arrive outside every receiver's window")

  # -- an endpoint on the notification -----------------------------------

  (array/clear received)
  (notify/send {:key :x :title "t" :to {:url (string endpoint "/hook")}})
  (assert (= 1 (length received)) "a notification that names its own endpoint goes there")

  # -- what a per-notification endpoint is not given ----------------------
  #
  # /mine is an allow-listed host but not the configured URL: the
  # delivery goes out, and the configured headers stay home — they are
  # the configured endpoint's credential, and this URL was chosen by
  # whoever created the notification.

  (array/clear received)
  (notify/send {:key :x :title "t" :to {:url (string endpoint "/mine")}})
  (assert (= 1 (length received)))
  (assert (nil? (get-in received [0 :headers "authorization"]))
          "the configured headers do not follow a per-notification URL")
  (assert (get-in received [0 :headers "x-void-signature"])
          "while the signature still does — it proves the sender, not the destination")

  # an override's own headers reach a foreign URL only through the
  # name whitelist: content-type may travel, a credential name may not
  (array/clear received)
  (notify/send {:key :x :title "t" :to {:url (string endpoint "/mine")}
                :webhook {:headers {"content-type" "application/vnd.acme+json"
                                    "authorization" "Bearer smuggled"
                                    "x-custom" "1"}}})
  (assert (= 1 (length received)))
  (assert (= "application/vnd.acme+json" (get-in received [0 :headers "content-type"]))
          "a whitelisted override header is applied")
  (assert (nil? (get-in received [0 :headers "authorization"]))
          "an override cannot smuggle a credential header to its own URL")
  (assert (nil? (get-in received [0 :headers "x-custom"])))

  # -- an address outside the allow-list is refused, not dialed ----------

  (def saved-allow (get webhook/settings :allow-hosts))
  (put webhook/settings :allow-hosts [])
  (array/clear received)
  (log/set-level! "void.notify" :fatal)
  (def blocked (notify/send {:key :x :title "t" :to {:url (string endpoint "/mine")}}))
  (log/set-level! "void.notify" :error)
  (assert (= :failed (get-in blocked [:results 0 :status]))
          "a per-notification URL at an address the deployment did not allow fails")
  (assert (empty? received) "and nothing was sent — the refusal happens before the socket")
  (put webhook/settings :allow-hosts saved-allow)

  (array/clear received)
  (notify/send {:key :x :title "t" :to {:email "ada@example.com"}})
  (assert (= 1 (length received))
          "while the configured URL is the operator's own value and is not filtered")

  # -- what the status code decides --------------------------------------

  (log/set-level! "void.notify" :fatal)
  (def gone (notify/send {:key :x :title "t" :to {:url (string endpoint "/gone")}}))
  (log/set-level! "void.notify" :error)
  (assert (= :failed (get-in gone [:results 0 :status])))
  (assert (webhook/permanent? {:status 404})
          "and the queue would record it rather than retry — see the jobs suite")

  # -- an unsigned webhook is a decision, not an accident ----------------

  (put webhook/settings :signing-key nil)
  (array/clear received)
  (notify/send {:key :x :title "t" :to {:url (string endpoint "/hook")}})
  (assert (nil? (get-in received [0 :headers "x-void-signature"]))
          "no secret, no signature — and the receiver that wanted one refuses, which is its right")
  (put webhook/settings :signing-key "shhh"))
