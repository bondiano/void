### void/mail/smtp — the SMTP client (RFC 5321, ADR-0026 §3).
###
### A connection is a `net/` stream and a buffer, the way a redis
### connection is: `net/read` and `net/write` park the fiber on the ev
### loop, so a mail being sent costs a fiber and not a thread
### (ADR-0010). The protocol is a conversation of lines, and the only
### thing that is easy to get wrong is that a reply may be several of
### them (`250-PIPELINING` … `250 8BITMIME`) — a client that reads one
### line answers the next command with the tail of this one.
###
### **This client speaks plaintext by default, and says so.** The
### default deployment stays ADR-0026's: a relay on the machine or
### next to it (Postfix, msmtp, a sidecar) holds the credentials and
### the TLS session, and the application talks to it over loopback.
### With `:void/tls` composed (ADR-0038), `[:mail :smtp :tls]` opens
### the second road: `:starttls` upgrades the session after EHLO and
### fails the delivery when the server cannot, `:smtps` speaks TLS
### from the first byte (the port-465 convention). Either setting
### without the plugin is a boot error naming it — a channel that was
### asked to be encrypted never quietly degrades to plaintext. A
### provider reached over HTTPS is an application's own
### `:void.mail/transport` contribution, as before.
###
### **AUTH over a plaintext connection to a remote host is refused.**
### Not warned about: refused, with the ways out named (`:tls`, a
### local relay, or `:allow-plaintext-auth` for a trusted private
### network). Sending a password in the clear is a decision somebody
### has to have made on purpose, and a default that makes it silently
### is how credentials end up on a hotel wifi. An encrypted session
### passes the gate by construction: AUTH runs after the handshake.
###
### **The reply code decides whether a failure is retried.** 4xx is
### transient and comes back as an error the job retries; 5xx is
### permanent and comes back as a rejection in the receipt — retrying
### "no such mailbox" five times annoys a server that already gave its
### final answer.

(import spork/base64)
(import void/core/log :as log)
(import ./address :as address)
(import ./message :as message)
(import ./transport :as transport)

(def log-ns "void.mail.smtp")

(def defaults
  ``The [:mail :smtp] slice.

  The default target is a relay on loopback port 25 — the deployment
  this client is built for (see the module docstring). `:timeout` is
  per command; RFC 5321 §4.5.3.2 asks for minutes on the data
  terminator, and a mailer that hangs a fiber for five of them is a
  mailer nobody can drain, so 60 seconds it is.``
  {:host "127.0.0.1"
   :port 25
   :username nil
   :password nil
   :auth :auto
   :helo nil
   # :none | :starttls (upgrade after EHLO, required once asked for) |
   # :smtps (TLS from the first byte — set :port 465 with it). Either
   # needs :void/tls in the composition (ADR-0038)
   :tls :none
   :timeout 60
   :connect-timeout 10
   :allow-plaintext-auth false})

(var tls-wrap
  ``How a connection is upgraded to TLS — `(fn [stream opts]
  tls-stream)` — or nil when this composition has none. `void/tls`
  installs its wrap here on load (ADR-0038 §4); while it is nil, a
  [:mail :smtp :tls] other than :none is a boot error (see
  `tls-refusal`), never a silent plaintext session.``
  nil)

# -- errors --------------------------------------------------------------

(defn smtp-error
  ``An SMTP failure as a value. `:permanent` is the whole point: the
  job that retries deliveries asks this and nothing else.``
  [code msg &opt extra]
  (merge {:mail/smtp true
          :code code
          :permanent (and code (>= code 500) (< code 600))
          :message msg}
         (or extra {})))

(defn permanent?
  "Did this failure already get its final answer from the server?"
  [err]
  (and (dictionary? err) (true? (get err :permanent))))

(defn- fail [code msg &opt extra]
  (error (smtp-error code msg extra)))

# -- the connection ------------------------------------------------------

(defn- deadline-call
  ``Run `f` under a timeout without touching the caller's root task:
  the work runs in a supervised child task and only that task is
  cancelled. The idiom (and the reason for it) is void/redis/conn's —
  `ev/deadline` on the caller would cancel the request being served.``
  [timeout f on-timeout]
  (def slot @{})
  (def sup (ev/chan 1))
  (def task (ev/go (fn timed [] (put slot :value (f)) (put slot :done true)) nil sup))
  (when (and timeout (pos? timeout)) (ev/deadline timeout task task))
  (def [status fiber] (ev/take sup))
  (cond
    (= :error status) (error (fiber/last-value fiber))
    (slot :done) (slot :value)
    (on-timeout)))

(defn- target [cfg]
  (string (get cfg :host "127.0.0.1") ":" (get cfg :port 25)))

(defn tls-refusal
  ``Why these settings may not be used, or nil: a [:mail :smtp :tls]
  other than :none in a composition without `void/tls` would either
  crash on the first delivery or — worse — quietly speak plaintext. A
  **pure** function of the configuration and the seam, asked at boot
  next to `auth-refusal`.``
  [cfg]
  (def mode (get cfg :tls :none))
  (cond
    (not (index-of mode [:none :starttls :smtps]))
    (string/format "[:mail :smtp :tls] must be :none, :starttls or :smtps, got %q" mode)

    (and (not= :none mode) (nil? tls-wrap))
    (string/format (string "[:mail :smtp :tls] is %q and this composition has no TLS — "
                           "add :void/tls to :plugins (ADR-0038), or set it :none and "
                           "point [:mail :smtp] at a relay on loopback")
                   mode)))

(defn open
  "Connect to the server. The connection is a table, so that the
  capabilities EHLO reports can be written on it. `:tls :smtps` runs
  the handshake here, before SMTP says a word."
  [cfg]
  (when-let [why (tls-refusal cfg)] (fail nil why))
  (def timeout (get cfg :connect-timeout (defaults :connect-timeout)))
  (def stream
    (deadline-call
      timeout
      (fn [] (net/connect (get cfg :host "127.0.0.1") (string (get cfg :port 25))))
      (fn [] (fail nil (string/format "connecting to %s timed out after %.1fs"
                                      (target cfg) timeout)))))
  (def secured
    (if (= :smtps (get cfg :tls :none))
      (do
        (def [ok wrapped]
          (protect (tls-wrap stream {:host (get cfg :host "127.0.0.1")
                                     :timeout timeout})))
        (unless ok
          (fail nil (string "smtps handshake with " (target cfg) " failed: "
                            (if (string? wrapped) wrapped (describe wrapped)))))
        wrapped)
      stream))
  @{:stream secured
    :buf @""
    :pos 0
    :cfg cfg
    :caps @{}
    :secure (= :smtps (get cfg :tls :none))
    :closed false})

(defn close
  "Close the connection. Never throws — a mail that was accepted is
  sent whatever the socket does afterwards."
  [c]
  (unless (c :closed)
    (put c :closed true)
    (protect (:close (c :stream))))
  nil)

(def max-reply-line
  ``The longest reply line this client reads before calling the reply
  malformed. RFC 5321 §4.5.3.1.5 caps a reply line at 512 octets; the
  eightfold slack forgives a chatty server, and the limit is what
  keeps a server (or a MITM on the plaintext default) that never
  sends a newline from growing the buffer until the process dies.``
  4096)

(def max-reply-lines
  ``How many lines one reply may run. EHLO answers a dozen; a server
  still sending continuation lines after fifty is not finishing a
  reply, it is feeding an unbounded array.``
  50)

(defn- read-line! [c]
  (def buf (c :buf))
  (def timeout (get-in c [:cfg :timeout] (defaults :timeout)))
  (var at (string/find "\n" buf (c :pos)))
  (while (nil? at)
    # bounded *before* the next read: a peer that streams bytes with
    # no line ending must hit a limit, not the allocator
    (when (> (- (length buf) (c :pos)) max-reply-line)
      (fail nil (string/format "reply line exceeds %d bytes without a line ending"
                               max-reply-line)))
    (def before (length buf))
    # a method call, not net/read: after STARTTLS the stream is a TLS
    # session (ADR-0038), which answers :read with the same signature
    (def [ok result] (protect (:read (c :stream) 4096 buf timeout)))
    (unless ok (fail nil (string "read failed: " result)))
    (when (or (nil? result) (= before (length buf)))
      (fail nil "the server closed the connection"))
    (set at (string/find "\n" buf (c :pos))))
  (when (> (- at (c :pos)) max-reply-line)
    (fail nil (string/format "reply line exceeds %d bytes" max-reply-line)))
  (def line (string/slice buf (c :pos) at))
  (put c :pos (inc at))
  (when (> (c :pos) 65536)
    (def tail (string/slice buf (c :pos)))
    (buffer/clear buf)
    (buffer/push buf tail)
    (put c :pos 0))
  (string/trimr line "\r"))

(defn read-reply
  ``Read one reply, however many lines it takes — up to
  `max-reply-lines`, past which the reply is a structural error rather
  than an array that grows as long as the server keeps hyphenating.
  Returns `{:code :lines :text}` — a continuation line is `250-…`, the
  last one `250 …`, and reading only the first is the bug that makes
  every later command answer with somebody else's reply.``
  [c]
  (def lines @[])
  (var code nil)
  (var done false)
  (while (not done)
    (when (>= (length lines) max-reply-lines)
      (fail nil (string/format "reply ran past %d lines without ending" max-reply-lines)))
    (def line (read-line! c))
    (when (< (length line) 3)
      (fail nil (string/format "malformed reply %q" line)))
    (def n (scan-number (string/slice line 0 3)))
    (unless (int? n) (fail nil (string/format "malformed reply %q" line)))
    (set code n)
    (array/push lines (string/slice line (min (length line) 4)))
    (set done (or (= 3 (length line)) (not= "-" (string/slice line 3 4)))))
  {:code code :lines lines :text (string/join lines " ")})

(defn- write! [c data]
  (def timeout (get-in c [:cfg :timeout] (defaults :timeout)))
  (def [ok result] (protect (:write (c :stream) data timeout)))
  (unless ok (fail nil (string "write failed: " result)))
  nil)

(defn command
  ``Send one command and read its reply. `expect` is the leading digit
  the caller needs (2 for "went through", 3 for "go on"); a reply that
  does not start with it is an error carrying the server's own words,
  because "550 5.7.1 Relay access denied" explains more than any
  message this client could write.``
  [c line expect &opt what]
  (write! c (string line "\r\n"))
  (def reply (read-reply c))
  (unless (= expect (div (reply :code) 100))
    (fail (reply :code)
          (string/format "%s: %d %s" (or what line) (reply :code) (reply :text))))
  reply)

# -- the conversation ----------------------------------------------------

(defn- helo-name [cfg]
  (or (get cfg :helo)
      # the name a relay on loopback never checks and a remote server
      # only logs; a deployment that needs its FQDN here configures it
      (let [h (os/getenv "HOSTNAME")]
        (if (and h (not (empty? h)) (address/ascii? h)) h "localhost"))))

(defn- parse-caps [reply]
  (def caps @{})
  (each line (drop 1 (reply :lines))
    (def parts (string/split " " (string/trim line)))
    (unless (empty? parts)
      (put caps (keyword (string/ascii-lower (first parts))) (drop 1 parts))))
  caps)

(defn- ehlo!
  "Introduce ourselves. ESMTP first; a server that refuses EHLO gets a
  plain HELO, which is the one fallback this client keeps — it costs
  three lines and it is what a minimal relay in a container answers."
  [c]
  (def name (helo-name (c :cfg)))
  (write! c (string "EHLO " name "\r\n"))
  (def reply (read-reply c))
  (if (= 2 (div (reply :code) 100))
    (put c :caps (parse-caps reply))
    (do (command c (string "HELO " name) 2 "HELO")
        (put c :caps @{}))))

(defn- secure!
  ``STARTTLS (RFC 3207): ask, hand the socket to void/tls, and forget
  everything learned before the handshake — capabilities *and* any
  buffered bytes, because both predate the protection (§4.2; bytes a
  server sent ahead of the handshake are exactly the injection the
  RFC warns about).``
  [c]
  (unless (get (c :caps) :starttls)
    (fail nil (string/format
                "[:mail :smtp :tls] is :starttls and %s does not offer STARTTLS"
                (target (c :cfg)))))
  (command c "STARTTLS" 2 "STARTTLS")
  (def cfg (c :cfg))
  (def [ok wrapped]
    (protect (tls-wrap (c :stream)
                       {:host (get cfg :host "127.0.0.1")
                        :timeout (get cfg :connect-timeout (defaults :connect-timeout))})))
  (unless ok
    (fail nil (string "STARTTLS handshake with " (target cfg) " failed: "
                      (if (string? wrapped) wrapped (describe wrapped)))))
  (put c :stream wrapped)
  (buffer/clear (c :buf))
  (put c :pos 0)
  (put c :caps @{})
  (put c :secure true))

(defn greet!
  ``Read the greeting, introduce ourselves, and secure the session
  when [:mail :smtp :tls] asks for it — :starttls upgrades here and
  introduces again, because the pre-handshake EHLO answer is not to
  be trusted (RFC 3207 §4.2).``
  [c]
  (def hello (read-reply c))
  (unless (= 220 (hello :code))
    (fail (hello :code) (string "greeting: " (hello :text))))
  (ehlo! c)
  (case (get-in c [:cfg :tls] :none)
    :starttls (do (secure! c) (ehlo! c))
    :none
    (when (get (c :caps) :starttls)
      (log/debug (string "the server offers STARTTLS and [:mail :smtp :tls] is :none — "
                         "this session is in the clear (set :starttls with :void/tls "
                         "composed, or keep the relay next to the application)")
                 :ns log-ns :server (target (c :cfg)))))
  c)

(defn- loopback? [host]
  (or (= host "localhost")
      (string/has-prefix? "127." (string host))
      (= host "::1")
      (= host "[::1]")))

(defn- reveal-password [cfg]
  (def p (get cfg :password))
  (cond
    (nil? p) nil
    (bytes? p) (string p)
    # a resolved secret box (ADR-0007) unwraps through void/core/config,
    # and the mailer does that before it gets here
    (errorf "[:mail :smtp :password] must be a string or an env reference, got %q" p)))

(defn- mechanism [c]
  (def cfg (c :cfg))
  (def offered (map string/ascii-upper (get-in c [:caps :auth] [])))
  (def wanted (get cfg :auth :auto))
  (case wanted
    :none nil
    :plain "PLAIN"
    :login "LOGIN"
    :auto (cond
            # no EHLO capabilities at all: a HELO-only relay that still
            # wants credentials gets PLAIN, which is the one every
            # server implements
            (empty? offered) "PLAIN"
            (index-of "PLAIN" offered) "PLAIN"
            (index-of "LOGIN" offered) "LOGIN"
            (fail nil (string/format
                        "%s offers AUTH %s and this client speaks PLAIN and LOGIN"
                        (target cfg) (string/join offered " "))))
    (errorf "[:mail :smtp :auth] must be :auto, :plain, :login or :none, got %q" wanted)))

(defn auth-refusal
  ``Why these settings may not send their password, or nil when they
  may. A **pure** function of the configuration, so the mailer asks it
  at boot: credentials that would go out in the clear are a
  misconfiguration, and finding it before the first login attempt
  costs nothing.``
  [cfg]
  (when (and (get cfg :username)
             (get cfg :password)
             (not= :none (get cfg :auth :auto))
             (not (loopback? (get cfg :host "127.0.0.1")))
             # an encrypted session passes by construction: AUTH runs
             # after the handshake :tls asked for (ADR-0038)
             (= :none (get cfg :tls :none))
             (not (get cfg :allow-plaintext-auth)))
    (string/format
      (string "refusing to send the SMTP password to %s in the clear. Set "
              "[:mail :smtp :tls] :starttls with :void/tls composed (ADR-0038), "
              "point [:mail :smtp] at a relay on loopback that holds the "
              "credentials, or set [:mail :smtp :allow-plaintext-auth] true if this "
              "network is trusted")
      (target cfg))))

(defn authenticate!
  ``AUTH, when there are credentials to send. Refuses to send them
  over a plaintext connection to a host that is not loopback — see the
  module docstring; `:allow-plaintext-auth true` is how a private
  network says it knows.``
  [c]
  (def cfg (c :cfg))
  (def user (get cfg :username))
  (def password (reveal-password cfg))
  (when (and user password)
    (when-let [why (auth-refusal cfg)] (fail nil why))
    (when-let [mech (mechanism c)]
      (case mech
        "PLAIN"
        (command c (string "AUTH PLAIN "
                           (base64/encode (string "\0" user "\0" password)))
                 2 "AUTH PLAIN")
        "LOGIN"
        (do (command c "AUTH LOGIN" 3 "AUTH LOGIN")
            (command c (base64/encode (string user)) 3 "AUTH LOGIN (username)")
            (command c (base64/encode (string password)) 2 "AUTH LOGIN (password)")))
      (put c :authenticated true)))
  c)

(defn dot-stuff
  ``Prepare a body for DATA: CRLF line endings, and a line that begins
  with a dot gets a second one (RFC 5321 §4.5.2). Without this, a
  message body containing a line \".\" ends the mail early and the
  rest of it is read as commands.``
  [body]
  (def normalized (string/replace-all "\n" "\r\n"
                                      (string/replace-all "\r\n" "\n" (string body))))
  (def out (string/replace-all "\r\n." "\r\n.." normalized))
  (if (string/has-prefix? "." out) (string "." out) out))

(defn send-message!
  ``One message over an open, greeted connection. Returns
  `{:accepted :rejected :reply}`; a recipient the server refused with
  5xx is *rejected*, not a failure — the mail still goes to the
  others, and who was refused travels back in the receipt.``
  [c delivery]
  (def msg (delivery :message))
  (command c (string "MAIL FROM:<" (msg :envelope-from) ">") 2 "MAIL FROM")
  (def accepted @[])
  (def rejected @[])
  (each rcpt (msg :recipients)
    (write! c (string "RCPT TO:<" rcpt ">\r\n"))
    (def reply (read-reply c))
    (cond
      (= 2 (div (reply :code) 100)) (array/push accepted rcpt)
      (= 5 (div (reply :code) 100))
      (array/push rejected {:email rcpt :code (reply :code) :message (reply :text)})
      # 4xx on a recipient is temporary and belongs to the whole
      # delivery: retrying the message is the only way to reach them
      (fail (reply :code)
            (string/format "RCPT TO <%s>: %d %s" rcpt (reply :code) (reply :text)))))
  (when (empty? accepted)
    (fail (get-in rejected [0 :code] 550)
          (string "every recipient was refused: "
                  (string/join (map |(string ($ :email) " (" ($ :message) ")") rejected) ", "))
          {:rejected rejected}))
  (command c "DATA" 3 "DATA")
  (write! c (dot-stuff (delivery :bytes)))
  (write! c "\r\n.\r\n")
  (def reply (read-reply c))
  (unless (= 2 (div (reply :code) 100))
    (fail (reply :code) (string/format "DATA: %d %s" (reply :code) (reply :text))
          {:rejected rejected}))
  {:accepted accepted :rejected rejected :reply reply})

(defn quit!
  "Say goodbye. Best effort: the message is already accepted."
  [c]
  (protect (command c "QUIT" 2 "QUIT"))
  (close c)
  nil)

(defn deliver!
  ``Send one delivery: connect, greet, authenticate, send, quit. A
  connection per message — a pool would save a handshake against a
  relay on loopback, which is where the handshake costs nothing, and
  would have to answer for a connection the server closed while it sat
  idle.``
  [cfg delivery]
  (unless (message/normalized? (delivery :message))
    (error "smtp/deliver! takes a delivery built by mail/send"))
  (def c (open cfg))
  (defer (close c)
    (greet! c)
    (authenticate! c)
    (def result (send-message! c delivery))
    (quit! c)
    (log/info "mail sent" :ns log-ns
              :server (target cfg)
              :to (result :accepted)
              :rejected (length (result :rejected))
              :id (delivery :id))
    (transport/receipt :smtp delivery
                       {:accepted (result :accepted)
                        :rejected (result :rejected)
                        :code (get-in result [:reply :code])})))

(defn transport
  "The `:void.mail/transport` contribution — `cfg` is read at send
  time, so a REPL that changes [:mail :smtp] changes the next mail."
  [cfg-fn]
  {:name :smtp
   :doc "Send over SMTP to the configured relay (plaintext: ADR-0010)"
   :send (fn smtp-send [delivery] (deliver! (cfg-fn) delivery))})
