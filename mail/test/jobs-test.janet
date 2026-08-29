(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/jobs :as jobs)
(import void/mail :as mail)
(import void/mail/smtp :as smtp)
(import void/mail/transport :as transport)
(require "void/html/init")
(require "void/mail/jobs")

(log/set-level! "void" :error)

(def plugins ["void/http/init" "void/html/init" "void/jobs/init"
              "void/mail/init" "void/mail/jobs"])

(defn- start [&opt extra]
  (test/start! {:plugins plugins
                :only [:http/kernel :jobs/queue]
                :profile :test
                :config {:env @{}
                         :cli (merge {:log {:level :error}
                                      :http {:port 0 :access-log false}
                                      # a disabled queue runs the handler inline
                                      # (void/jobs' own switch for a suite), which is
                                      # exactly what this suite needs: the routing is
                                      # what is under test, not the worker
                                      :jobs {:enabled false}
                                      :mail {:transport :memory
                                             :from "void <no-reply@example.com>"
                                             :base-url "https://example.com"}}
                                     (or extra {}))}}))

(def boot (start))

(defer (test/stop! boot)
  (mail/clear-outbox!)

  (assert (mail/queued?)
          "composing void/mail-jobs is the whole of \"send mail through a queue\" — no call site changes")

  (def receipt (mail/send {:to "ada@example.com" :subject "hi" :text "body"}))
  (assert (receipt :queued) "the receipt says the letter was handed over")
  (assert (receipt :id) "and carries the Message-ID either way, so a caller logs the same thing")
  (assert (= 1 (length (mail/outbox)))
          "with [:jobs :enabled] false the handler ran inline and the letter went out")

  # what is queued is the rendered letter, not the arguments that
  # would render it: the retry sends the same mail, with the same
  # Message-ID
  (def queued (get-in (mail/outbox) [0]))
  (assert (= (receipt :id) (queued :id)))
  (assert (string/find "Subject: hi" (queued :bytes)))

  # -- a rejection is recorded, not retried -----------------------------
  (def delivery (mail/build {:to "ada@example.com" :subject "hi" :text "body"}))

  (put mail/transports :refuses
       {:name :refuses :doc "always 550"
        :send (fn [_] (error (smtp/smtp-error 550 "5.1.1 no such user")))})
  (put mail/transports :later
       {:name :later :doc "always 451"
        :send (fn [_] (error (smtp/smtp-error 451 "4.3.0 try later")))})

  (put mail/settings :transport :refuses)
  # the rejection is logged at :error by design — this is the one place
  # that expects it, so the namespace is quiet for the assertion
  (log/set-level! "void.mail.jobs" :fatal)
  (def rejected (jobs/perform :mail-deliver delivery))
  (assert (rejected :rejected)
          "a 5xx comes back as a completed job carrying the rejection — the server has answered, and a retry can change nothing")
  (assert (= 550 (rejected :code)))

  (put mail/settings :transport :later)
  (assert (not (first (protect (jobs/perform :mail-deliver delivery))))
          "a 4xx is thrown, so the queue's retry policy takes it")

  (log/set-level! "void.mail.jobs" :error)
  (put mail/settings :transport :memory)

  # -- the job's own policy ---------------------------------------------
  (def opts ((jobs/job-of :mail-deliver) :opts))
  (assert (= :mail (opts :queue))
          "mail has its own queue, so [:jobs :queues :mail] is where a deployment tunes it")
  (assert (= 5 (opts :max-attempts))))

# -- [:mail :queue] false opts out --------------------------------------

(def direct (start {:mail {:transport :memory :queue false
                           :from "void <no-reply@example.com>"}}))
(defer (test/stop! direct)
  (mail/clear-outbox!)
  (def receipt (mail/send {:to "a@b.co" :subject "s" :text "x"}))
  (assert (not (receipt :queued)))
  (assert (= :memory (receipt :transport))
          "an application that wants the request to wait for the socket can say so"))
