(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/auth :as auth)
(import void/crypto :as crypto)
(import void/mail :as mail)
(import void/mail/auth :as mail-auth)
(require "void/html/init")
(require "void/crypto/init")
(require "void/auth/init")
(require "void/mail/auth")

(log/set-level! "void" :error)

# The half of the wave-3 exit criterion that waited for this package:
# void/auth issues magic links and one-time codes and deliberately does
# not deliver them. This is the delivery.

(def plugins ["void/http/init" "void/html/init" "void/crypto/init"
              "void/auth/init" "void/mail/init" "void/mail/auth"])

(defn- start [&opt extra]
  (test/start! {:plugins plugins
                :only [:http/kernel :crypto/lib :auth/registry]
                :profile :test
                :config {:env @{}
                         :cli (merge {:log {:level :error}
                                      :http {:port 0 :access-log false}
                                      :crypto {:kdf {:in-thread false}}
                                      :mail {:transport :memory
                                             :from "Example <no-reply@example.com>"
                                             :base-url "https://example.com"}}
                                     (or extra {}))}}))

(def boot (start))

(defer (test/stop! boot)
  (mail/clear-outbox!)

  # -- a magic link, end to end ------------------------------------------
  (def issued (auth/challenge! "user:42" {:to "ada@example.com"}))
  (assert (nil? (issued :code))
          "the code is not in the return value: it exists inside the call and inside the letter, and nowhere a log can reach")
  (assert (deep= @[:mail/challenge] (issued :delivered)))
  (assert (= 1 (length (mail/outbox))))

  (def letter (get-in (mail/outbox) [0]))
  (assert (string/find "To: ada@example.com" (letter :bytes)))
  (assert (string/find "Subject: Sign in to Example" (letter :bytes))
          "the letter calls the application by the display name of the sender")

  # the link in the letter is the one the visitor can actually redeem:
  # undo the transfer encoding the way a mail client does, then read
  # the URL out of the text part
  (def decoded (string/replace-all "=3D" "="
                                   (string/replace-all "=\r\n" "" (letter :bytes))))
  (def link
    (first (peg/match
             ~(any (+ (<- (* "https://example.com/auth/magic?h="
                             (some (if-not (set "&\"< \r\n") 1))
                             "&c="
                             (some (if-not (set "&\"< \r\n") 1))))
                      1))
             decoded)))
  (assert link "the letter carries a link")
  (def [handle code] (string/split "&c=" (string/slice link (+ 3 (string/find "?h=" link)))))

  (def id (auth/redeem! handle code))
  (assert id "the code from the letter redeems into an identity")
  (assert (= "user:42" (id :subject)))
  (assert (= :magic-link (id :via)))
  (assert (nil? (auth/redeem! handle code))
          "and once — the second attempt has nothing left to take")

  # -- a one-time code ---------------------------------------------------
  (mail/clear-outbox!)
  (auth/challenge! "user:7" {:to "grace@example.com" :kind :otp})
  (def otp-letter (get-in (mail/outbox) [0]))
  (assert (string/find "Content-Type: text/plain" (otp-letter :bytes)))
  (assert (peg/match ~(any (+ (* "code for Example: " (<- (between 6 6 :d))) 1))
                     (otp-letter :bytes))
          "six digits a person can type, in the text part")

  # -- a challenge this plugin is not for --------------------------------
  (mail/clear-outbox!)
  (assert (not (first (protect (auth/challenge! "user:9" {:kind :otp :channel :sms}))))
          "a challenge nobody delivered is an error: the visitor is waiting for a code that is not coming, and the alternative is a login page that spins with nothing in any log")
  (assert (empty? (mail/outbox)))

  (assert (not (first (protect (auth/challenge! "user:9" {}))))
          "including one with no address to mail it to")

  # -- the letter is replaceable without an extension point --------------
  (mail/clear-outbox!)
  (def original mail-auth/link-view)
  (set mail-auth/link-view (fn [ch] [:p "our own letter: " (mail-auth/link-for ch)]))
  (auth/challenge! "user:1" {:to "ada@example.com"})
  (assert (string/find "our own letter" (get-in (mail/outbox) [0 :bytes])))
  (set mail-auth/link-view original)

  # -- a preview, for whoever has to look at it --------------------------
  (def preview (mail/preview (mail-auth/letter {:kind :link :handle "h" :code "c"
                                                :to "ada@example.com"
                                                :expires (+ (os/time) 900)})))
  (assert (string/find "https://example.com/auth/magic?h=3Dh&c=3Dc" preview)
          "the link is built from [:mail :base-url] and [:mail-auth :link-path]")
  (assert (string/find "15 more minutes" preview)
          "and the letter says how long it is good for"))

# -- the path a deployment configures ------------------------------------

(def elsewhere (start {:mail-auth {:link-path "/enter" :app-name "Blog"
                                   :subject "Your link"}}))
(defer (test/stop! elsewhere)
  (mail/clear-outbox!)
  (auth/challenge! "user:2" {:to "ada@example.com"})
  (def bytes (get-in (mail/outbox) [0 :bytes]))
  (assert (string/find "Subject: Your link" bytes))
  (assert (string/find "https://example.com/enter?h=3D" bytes)))
