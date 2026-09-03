# The plugin and its seams, end to end: one boot, and
# then https:// through void/http/client, RESP over a rediss-shaped
# connection, and an SMTP delivery that upgrades with STARTTLS — every
# consumer talking to a real TLS server on a real socket, none of them
# knowing more than they did in the clear.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/tls/stream :as stream)
(import void/tls/init :as tls)
(import void/http/client :as client)
(import void/redis/conn :as redis-conn)
(import void/mail/smtp :as smtp)
(import void/mail/message :as message)
(import void/mail/mime :as mime)
(import ../test-support/tls-server :as tls-server)

(log/set-level! "void" :error)

# before any boot the seams are open: importing the module is not
# composing the plugin, and "is there TLS" is a fact about the composition
(assert (not (client/tls-available?)) "an import alone closes no seam")

# -- what the boot refuses -----------------------------------------------

# a composition that turns verification off in :prod does not start
(def [pok perr]
  (protect
    (plugin/start!
      {:plugins ["void/crypto/init" "void/tls/init"]
       :profile :prod
       :config {:env @{}
                :cli {:log {:level :error} :tls {:verify false}}}})))
(assert (not pok) "[:tls :verify] false in :prod is a boot error")
(assert (string/find "certificates" (string perr)) "that says what to do instead")

# -- boot: the component opens libssl and builds the shared context ------

(def boot
  (plugin/start!
    {:plugins ["void/crypto/init" "void/tls/init"]
     :profile :test
     :config {:env @{}
              :cli {:log {:level :error}
                    :tls {:ca-file "test-support/certs/server-cert.pem"}}}}))

(defer (plugin/shutdown! boot 3)

  # the boot's load phase ran install!: every seam is closed now
  (assert (client/tls-available?) "booting the plugin closes the http client seam")
  (assert (not (nil? redis-conn/tls-connect)) "and the redis seam")
  (assert (not (nil? smtp/tls-wrap)) "and the mail seam")

  # -- https:// through the http client ----------------------------------

  (def web (tls-server/start
             (fn [ts]
               (def buf @"")
               (while (nil? (string/find "\r\n\r\n" buf))
                 (unless (:read ts 4096 buf 5) (break)))
               (:write ts (string "HTTP/1.1 200 OK\r\n"
                                  "content-type: text/plain\r\n"
                                  "content-length: 12\r\n"
                                  "connection: close\r\n\r\n"
                                  "hello, tls!\n")))))

  (def resp (client/request {:url (string "https://127.0.0.1:" (web :port) "/hi")}))
  (assert (= 200 (resp :status)) "a GET over https answers")
  (assert (= "hello, tls!\n" (resp :body)) "with its body intact")
  (tls-server/stop web)

  # the URL parser knows 443 the way it knows 80
  (assert (= "443" ((client/parse-url "https://api.example/x") :port)))

  # -- RESP over TLS: what a rediss:// URL opens -------------------------

  (def resp-server
    (tls-server/start
      (fn [ts]
        (def buf @"")
        (while (nil? (string/find "PING" buf))
          (unless (:read ts 4096 buf 5) (break)))
        (:write ts "+PONG\r\n"))))

  (def rc (redis-conn/open {:host "127.0.0.1" :port (resp-server :port)
                            :tls true :protocol 2 :timeout 5}))
  (assert (= "PONG" (string (redis-conn/call rc ["PING"]))) "PING went out encrypted and came back")
  (redis-conn/close rc)
  (tls-server/stop resp-server)

  # -- SMTP with STARTTLS ------------------------------------------------

  (def smtp-listener (net/listen "127.0.0.1" "0"))
  (def [_ smtp-port] (net/localname smtp-listener))
  (def server-ctx (stream/context {:server? true
                                   :cert tls-server/cert :key tls-server/key}))
  (def seen @[])
  (ev/go
    (fn smtp-server []
      (with [conn (net/accept smtp-listener)]
        (defn talk [stream script]
          (def buf @"")
          (var pos 0)
          (defn line []
            (var at (string/find "\n" buf pos))
            (while (nil? at)
              (unless (:read stream 4096 buf 5) (break))
              (set at (string/find "\n" buf pos)))
            (when at
              (def out (string/trimr (string/slice buf pos at) "\r"))
              (set pos (inc at))
              out))
          (var in-data false)
          (each [expect reply] script
            (var got (line))
            (when in-data
              (def body @"")
              (while (and got (not= "." got))
                (buffer/push body got "\n")
                (set got (line)))
              (array/push seen (string body))
              (set in-data false))
            (when got
              (array/push seen got)
              (when expect
                (assert (string/has-prefix? expect got)
                        (string "smtp server expected " expect ", got " got)))
              (:write stream (string reply "\r\n"))
              (when (string/has-prefix? "DATA" got) (set in-data true)))))
        # the clear half: greeting, EHLO, STARTTLS
        (:write conn "220 test.example ESMTP\r\n")
        (talk conn [["EHLO" "250-test.example\r\n250 STARTTLS"]
                    ["STARTTLS" "220 go ahead"]])
        # the handshake, then the same conversation encrypted
        (def ts (stream/wrap conn {:ctx server-ctx :accept? true :timeout 5}))
        (talk ts [["EHLO" "250-test.example\r\n250 8BITMIME"]
                  ["MAIL FROM:<no-reply@example.com>" "250 ok"]
                  ["RCPT TO:<ada@example.com>" "250 ok"]
                  ["DATA" "354 go ahead"]
                  [nil "250 queued"]
                  ["QUIT" "221 bye"]])
        (protect (:close ts)))))

  (def msg (message/normalize {:to "ada@example.com" :subject "hi" :text "body"}
                              {:from "void <no-reply@example.com>"}))
  (def receipt
    (smtp/deliver! {:host "127.0.0.1" :port smtp-port :timeout 5 :tls :starttls}
                   {:message msg
                    :bytes (mime/render msg {:message-id "<id@example.com>"
                                             :date 1756400000})
                    :id "<id@example.com>"
                    :at 1756400000}))
  (assert (deep= @["ada@example.com"] (receipt :accepted))
          "the delivery went through the upgraded session")
  (assert (= 2 (length (filter |(string/has-prefix? "EHLO" $) seen)))
          "EHLO was sent again after the handshake — the pre-STARTTLS answer is not trusted (RFC 3207 §4.2)")
  (assert (string/find "Subject: hi" (string/join seen "\n")) "and the message arrived")
  (protect (:close smtp-listener))
  (stream/close-context server-ctx)

  # -- the gates ---------------------------------------------------------

  # AUTH over :starttls passes the plaintext gate by construction
  (assert (nil? (smtp/auth-refusal {:host "mail.example" :username "u" :password "p"
                                    :tls :starttls}))
          "credentials over an encrypted session are not credentials in the clear")
  (assert (smtp/auth-refusal {:host "mail.example" :username "u" :password "p"})
          "and over plaintext to a remote host they are still refused"))

(print "plugin-test ok")
