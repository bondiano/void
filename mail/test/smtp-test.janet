(import ../test-support/paths)
(import void/core/log :as log)
(import void/mail/message :as message)
(import void/mail/mime :as mime)
(import void/mail/smtp :as smtp)

(log/set-level! "void" :error)

# A real socket and a scripted server. The protocol is a conversation,
# and the two things that are easy to get wrong in it — a multi-line
# reply read as one line, and a body line that begins with a dot — are
# invisible to any test that stubs the conversation out.

(defn- server
  ``Answer one connection from `script`: a list of [expected-prefix
  reply] pairs, matched in order against the lines the client sends.
  Returns [stop-fn port received] — `received` fills up as the
  conversation happens.``
  [script]
  (def received @[])
  (def listener (net/server "127.0.0.1" "0"))
  (def [_ port] (net/localname listener))
  (def stopped @{})
  (ev/go
    (fn serve []
      (def [ok] (protect
                  (with [conn (net/accept listener)]
                    (def buf @"")
                    (var pos 0)
                    (defn line []
                      (var at (string/find "\n" buf pos))
                      (while (nil? at)
                        (unless (net/read conn 4096 buf 5) (break))
                        (set at (string/find "\n" buf pos)))
                      (when at
                        (def out (string/trimr (string/slice buf pos at) "\r"))
                        (set pos (inc at))
                        out))
                    (net/write conn "220 test.example ESMTP\r\n")
                    (var in-data false)
                    (each [expect reply] script
                      (var got (line))
                      (when in-data
                        # swallow the body up to the lone dot, keeping it
                        (def body @"")
                        (while (and got (not= "." got))
                          (buffer/push body got "\n")
                          (set got (line)))
                        (array/push received (string body))
                        (set in-data false))
                      (when got
                        (array/push received got)
                        (when (and expect (not (string/has-prefix? expect got)))
                          (net/write conn "500 unexpected\r\n")
                          (break))
                        (net/write conn (string reply "\r\n"))
                        (when (string/has-prefix? "DATA" got) (set in-data true)))))))
      (put stopped :done true)
      (:close listener)))
  [(fn [] (protect (:close listener))) port received])

(def cfg-from {:from "void <no-reply@example.com>"})

(defn- delivery [&opt msg]
  (def m (message/normalize (merge {:to "ada@example.com" :subject "hi" :text "body"}
                                   (or msg {}))
                            cfg-from))
  {:message m
   :bytes (mime/render m {:message-id "<id@example.com>" :date 1756400000})
   :id "<id@example.com>"
   :at 1756400000})

# -- the happy path, with a multi-line EHLO -----------------------------

(def [stop port received]
  (server [["EHLO" "250-test.example greets you\r\n250-PIPELINING\r\n250 8BITMIME"]
           ["MAIL FROM:<no-reply@example.com>" "250 2.1.0 ok"]
           ["RCPT TO:<ada@example.com>" "250 2.1.5 ok"]
           ["DATA" "354 go ahead"]
           [nil "250 2.0.0 queued as ABC123"]
           ["QUIT" "221 bye"]]))

(def receipt (smtp/deliver! {:host "127.0.0.1" :port port :timeout 5} (delivery)))
(stop)

(assert (= :smtp (receipt :transport)))
(assert (deep= @["ada@example.com"] (receipt :accepted)))
(assert (= 250 (receipt :code)))
(assert (deep= ["EHLO" "MAIL" "RCPT" "DATA" "QUIT"]
               (tuple ;(seq [line :in received
                             :let [word (first (string/split " " line))]
                             :when (index-of word ["EHLO" "MAIL" "RCPT" "DATA" "QUIT"])]
                        word)))
        "the greeting was read to its last line — a client that stopped at the first would have sent MAIL FROM against 250-PIPELINING and been refused")
(assert (string/find "Subject: hi" (string/join received "\n")) "and the message arrived")

# -- a rejected recipient is not a failed delivery ----------------------

(def [stop2 port2 received2]
  (server [["EHLO" "250 test.example"]
           ["MAIL FROM" "250 ok"]
           ["RCPT TO:<ada@example.com>" "550 5.1.1 no such user"]
           ["RCPT TO:<grace@example.com>" "250 ok"]
           ["DATA" "354 go ahead"]
           [nil "250 queued"]
           ["QUIT" "221 bye"]]))

(def partial (smtp/deliver! {:host "127.0.0.1" :port port2 :timeout 5}
                            (delivery {:to ["ada@example.com" "grace@example.com"]})))
(stop2)

(assert (deep= @["grace@example.com"] (partial :accepted)))
(assert (= 1 (length (partial :rejected))))
(assert (= 550 (get-in partial [:rejected 0 :code]))
        "who was refused travels back by name — \"partly sent\" is the normal outcome of a multi-recipient mail")

# -- every recipient refused: permanent, and not for the queue to retry -

(def [stop3 port3]
  (server [["EHLO" "250 test.example"]
           ["MAIL FROM" "250 ok"]
           ["RCPT TO" "550 5.1.1 no such user"]]))
(def [ok err] (protect (smtp/deliver! {:host "127.0.0.1" :port port3 :timeout 5} (delivery))))
(stop3)
(assert (not ok))
(assert (smtp/permanent? err) "a 5xx is the server's final answer, and a retry would only annoy it")

# -- a 4xx is transient, and is thrown for the queue --------------------

(def [stop4 port4]
  (server [["EHLO" "250 test.example"]
           ["MAIL FROM" "451 4.3.0 try later"]]))
(def [ok4 err4] (protect (smtp/deliver! {:host "127.0.0.1" :port port4 :timeout 5} (delivery))))
(stop4)
(assert (not ok4))
(assert (not (smtp/permanent? err4)) "a 4xx is worth retrying")
(assert (= 451 (err4 :code)))

# -- dot-stuffing --------------------------------------------------------

(def [stop5 port5 received5]
  (server [["EHLO" "250 test.example"]
           ["MAIL FROM" "250 ok"]
           ["RCPT TO" "250 ok"]
           ["DATA" "354 go ahead"]
           [nil "250 queued"]
           ["QUIT" "221 bye"]]))
(smtp/deliver! {:host "127.0.0.1" :port port5 :timeout 5}
               (delivery {:text "before\n.\nafter"}))
(stop5)
(assert (string/find "\n..\n" (string/join received5 "\n"))
        "a body line that is a single dot is stuffed — unstuffed, it ends the message early and the rest is read as commands")

# -- AUTH in the clear ---------------------------------------------------

(def [stop6 port6 received6]
  (server [["EHLO" "250-test.example\r\n250 AUTH PLAIN LOGIN"]
           ["AUTH PLAIN" "235 2.7.0 authenticated"]
           ["MAIL FROM" "250 ok"]
           ["RCPT TO" "250 ok"]
           ["DATA" "354 go ahead"]
           [nil "250 queued"]
           ["QUIT" "221 bye"]]))
(smtp/deliver! {:host "127.0.0.1" :port port6 :timeout 5
                :username "void" :password "s3cret"}
               (delivery))
(stop6)
(assert (string/find "AUTH PLAIN" (string/join received6 " "))
        "credentials go to a relay on loopback, which is the deployment this client is for")

(def remote {:host "smtp.example.com" :port 587 :username "void" :password "s3cret"})
(assert (string/find "in the clear" (smtp/auth-refusal remote))
        "and to a remote host they are refused — void has no TLS, and a password in the clear must be a decision somebody typed")
(assert (nil? (smtp/auth-refusal (merge remote {:allow-plaintext-auth true})))
        "which a private network can say it knows about")
(assert (nil? (smtp/auth-refusal {:host "127.0.0.1" :username "void" :password "s"}))
        "a relay on loopback is the deployment this client is for")
(assert (nil? (smtp/auth-refusal {:host "smtp.example.com"}))
        "and a server that wants no credentials has none to leak")

# -- the pure halves -----------------------------------------------------

(assert (= "a\r\n..\r\nb" (smtp/dot-stuff "a\n.\nb")))
(assert (= "..x" (smtp/dot-stuff ".x")) "including the very first line")
(assert (smtp/permanent? (smtp/smtp-error 550 "no")))
(assert (not (smtp/permanent? (smtp/smtp-error 421 "later"))))
(assert (not (smtp/permanent? (smtp/smtp-error nil "connection refused")))
        "a connection that never opened is worth retrying")
