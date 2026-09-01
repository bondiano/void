# The mail channel: the letter is rendered where send was called, it
# goes out through void/mail's own routing, and a notification with no
# address for it is skipped rather than failed.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/mail :as mail)
(import void/notify :as notify)
(import void/notify/mail :as notify-mail)
(require "void/html/init")
(require "void/notify/mail")

(log/set-level! "void" :error)

(def plugins ["void/http/init" "void/html/init" "void/mail/init"
              "void/notify/init" "void/notify/mail"])

(defn- start [&opt extra]
  (test/start! {:plugins plugins :only [:http/kernel]
                :profile :test
                :config {:env @{}
                         :cli (merge {:log {:level :error}
                                      :http {:port 0 :access-log false}
                                      :mail {:transport :memory
                                             :from "void <no-reply@example.com>"
                                             :base-url "https://example.com"}}
                                     (or extra {}))}}))

(def boot (start))

(defer (test/stop! boot)
  (mail/clear-outbox!)

  (assert (deep= @[:mail] (notify/active))
          "[:notify :channels] unsaid is the composition read back: every contributed channel that delivers somewhere, and never :memory or :log")

  # -- an ordinary notification -----------------------------------------

  (def result (notify/send {:key :order/shipped
                            :title "Your order shipped"
                            :body "Order #1042 is on its way."
                            :url "/orders/1042"
                            :to {:email "ada@example.com" :subject "user:42"}}))

  (assert (= :sent (get-in result [:results 0 :status])))
  (assert (= 1 (length (mail/outbox))))

  (def delivery (get-in (mail/outbox) [0]))
  (assert (deep= @["ada@example.com"] (get-in delivery [:message :recipients])))
  (assert (= "Your order shipped" (get-in delivery [:message :subject]))
          "the title is the subject when the notification does not say otherwise")
  (assert (= (result :id) (get-in delivery [:message :headers "X-Void-Notification"]))
          "and the letter carries the notification's id, so a mailbox and a bell can be told to be one event")
  (assert (string/find "https://example.com/orders/1042" (get-in delivery [:message :html]))
          "a relative :url is absolute in a letter — a mail has no origin (ADR-0026 §4)")
  (assert (string/find "Order #1042 is on its way." (get-in delivery [:message :text]))
          "and the plain-text half is generated, not forgotten")

  # -- the id survives the projection ------------------------------------

  (def receipt (get-in result [:results 0 :receipt]))
  (assert (= (result :id) (receipt :id)) "the receipt speaks about the notification")
  (assert (= (delivery :id) (receipt :message-id))
          "and carries the Message-ID beside it, because that is what a mail log has")

  # -- not this channel's business ---------------------------------------

  (mail/clear-outbox!)
  (def no-address (notify/send {:key :x :title "t" :to {:subject "user:42"}}))
  (assert (= :skipped (get-in no-address [:results 0 :status])))
  (assert (empty? (mail/outbox)) "nothing was sent, and nothing pretended to be")
  (assert (not (notify/delivered? no-address)))

  # -- the per-notification override -------------------------------------

  (mail/clear-outbox!)
  (notify/send {:key :x :title "In the bell it says this"
                :to {:email "ada@example.com"}
                :mail {:subject "In the inbox it says this"
                       :view [:p "and the letter is one the application wrote"]}})
  (def overridden (get-in (mail/outbox) [0 :message]))
  (assert (= "In the inbox it says this" (overridden :subject)))
  (assert (string/find "one the application wrote" (overridden :html)))

  # -- the view is a var -------------------------------------------------

  (mail/clear-outbox!)
  (def original notify-mail/view)
  (set notify-mail/view (fn [note] [:p "replaced: " (note :title)]))
  (notify/send {:key :x :title "t" :to {:email "ada@example.com"}})
  (set notify-mail/view original)
  (assert (string/find "replaced: t" (get-in (mail/outbox) [0 :message :html]))
          "an application replaces the letter by assignment — a point here would be a second way to do what a var does")

  # -- the letter is available without sending it ------------------------

  (def preview (mail/preview (notify-mail/letter
                               (notify/normalize {:key :x :title "Preview me"
                                                  :to {:email "ada@example.com"}}
                                                 [:mail])
                               "ada@example.com")))
  (assert (string/find "Subject: Preview me" preview)
          "the letter is a public function of the notification, so a REPL can look at it"))

# -- the queue decision stays void/mail's --------------------------------

(def queued (start {:mail {:transport :memory :queue false
                           :from "void <no-reply@example.com>"
                           :base-url "https://example.com"}}))
(defer (test/stop! queued)
  (mail/clear-outbox!)
  (def r (notify/send {:key :x :title "t" :to {:email "ada@example.com"}}))
  (assert (= :sent (get-in r [:results 0 :status])))
  (assert (not (get-in r [:results 0 :receipt :queued]))
          "[:mail :queue] false is still what decides — the channel hands the built letter back to mail/send-delivery rather than to a transport"))
