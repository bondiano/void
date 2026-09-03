(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/mail :as mail)
(import void/mail/transport :as transport)
(require "void/html/init")

(log/set-level! "void" :error)

(def plugins ["void/http/init" "void/html/init" "void/mail/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}
                :http {:port 0 :access-log false}
                :mail {:transport :memory
                       :from "void <no-reply@example.com>"
                       :base-url "https://example.com"}}
               extra)})

(defn- start [&opt extra profile]
  (test/start! {:plugins plugins :only [:http/kernel]
                :profile (or profile :test)
                :config (config (or extra {}))}))

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok))
(assert (= 4 (get-in report [:extensions :void.mail/transport :contributions]))
        "the package ships :memory, :file, :log and :smtp")

# -- what the boot refuses -----------------------------------------------

(each [extra reason]
  [[{:mail {:transport :postmark}} "a transport nobody contributed"]
   [{:mail {:transport :smtp :smtp {:host "smtp.example.com"
                                    :username "void" :password "s3cret"}}}
    "credentials that would go out in the clear (no TLS on this transport)"]]
  (assert (not (first (protect (start extra))))
          (string reason " stops the boot")))

(def [ok err]
  (protect (test/start! {:plugins plugins :only [:http/kernel] :profile :prod
                         :config {:env @{}
                                  :cli {:log {:level :error}
                                        :http {:port 0 :access-log false}
                                        :mail {:transport :file
                                               :from "void <no-reply@example.com>"}}}})))
(assert (not ok) "in production a transport that keeps mail rather than sending it is a boot error")
(assert (string/find "does not send mail" (string err))
        "and the message says so, because a deployment that silently mails nothing looks exactly like one that works")

(def [ok2 err2] (protect (start {:mail {:transport :memory :queue true
                                        :from "void <no-reply@example.com>"}})))
(assert (not ok2) "[:mail :queue] true without a queue in the composition is a boot error too")
(assert (string/find "void/mail-jobs" (string err2)) "naming what is missing")

# -- a booted mailer -----------------------------------------------------

(def boot (start))

(defer (test/stop! boot)
  (mail/clear-outbox!)

  (assert (= :memory ((mail/active-transport) :name)))
  (assert (not (mail/queued?)) "without void/mail-jobs a message goes out on the calling fiber")

  (def receipt (mail/send {:to "ada@example.com" :subject "hi" :text "body"}))
  (assert (= :memory (receipt :transport)))
  (assert (deep= @["ada@example.com"] (receipt :accepted)))
  (assert (= 1 (length (mail/outbox))))
  (assert (string/find "From: void <no-reply@example.com>" (get-in (mail/outbox) [0 :bytes]))
          "the [:mail :from] a message did not carry")

  # the seam void/bus takes and obs can count
  (def seen @[])
  (mail/listen! :test (fn [r] (array/push seen (r :id))))
  (def second (mail/send {:to "grace@example.com" :subject "hi" :text "body"}))
  (mail/unlisten! :test)
  (assert (deep= @[(second :id)] seen) "every receipt passes through the hook")

  (def health (first (filter |(= :mail/transport ($ :name))
                             (plugin/extension boot :void.core/health))))
  (def h ((health :fn)))
  (assert (= :up (h :status)))
  (assert (= :memory (h :transport)))
  (assert (not (h :queued)))

  # -- the CLI -----------------------------------------------------------
  (def cli (from-pairs (map |[($ :name) $] (plugin/extension boot :void.core/cli))))
  (assert (get cli :mail/status))
  (assert (get cli :mail/send))
  (assert (get cli :mail/outbox))
  (assert (not (first (protect (((cli :mail/status) :fn) "extra"))))
          "a CLI command with arguments it does not take says so")
  (mail/clear-outbox!)
  (((cli :mail/send) :fn) "ada@example.com")
  (assert (= 1 (length (mail/outbox))) "void mail send is how a deployment finds out whether it can mail at all")

  # -- what a message inherits, and what it may override -----------------
  (assert (string/find "Reply-To: help@example.com"
                       (mail/preview {:to "a@b.co" :subject "s" :text "x"
                                      :reply-to "help@example.com"})))
  (assert (not (first (protect (mail/send {:subject "s" :text "x"}))))
          "a message with no recipient is a bug in the caller and is refused here, not silently dropped"))

# -- the staging override, end to end ------------------------------------

(def redirected (start {:mail {:transport :memory
                               :from "void <no-reply@example.com>"
                               :to-override "dev@example.com"}}))
(defer (test/stop! redirected)
  (mail/clear-outbox!)
  (def r (mail/send {:to "customer@example.com" :subject "s" :text "x"}))
  (assert (deep= @["dev@example.com"] (r :accepted)))
  (assert (string/find "X-Void-Original-To: customer@example.com"
                       (get-in (mail/outbox) [0 :bytes]))
          "and the mail says who it would have gone to"))
