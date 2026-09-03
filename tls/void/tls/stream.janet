### void/tls/stream — a TLS session as a stream-shaped table.
###
### The whole trick is that SSL never sees a socket. Each session gets
### a pair of memory BIOs: SSL reads ciphertext out of one and writes
### ciphertext into the other, and this module is the pump between
### those BIOs and the real stream underneath. Every `SSL_*` call
### therefore returns immediately — plaintext, or WANT_READ — and the
### fiber parks exactly where it always parked: on the underlying
### stream's read and write. The event-loop discipline is
### untouched by construction.
###
### What comes back from `wrap`/`connect` is a table with `:read`,
### `:write` and `:close` methods carrying the same signatures janet's own
### streams answer to — `(:read s n buf timeout)` appends into `buf` and
### returns it, nil on EOF, and a timeout surfaces as the same "timeout"
### error `net/read` raises, because it *is* that error, propagated from
### the raw read the fiber was parked on. A consumer that switched from
### `(net/read s ...)` to `(:read s ...)` stops knowing whether a socket
### or a TLS session is underneath; that is the entire integration
### contract.
###
### Verification is part of the handshake, not an afterthought:
### `SSL_VERIFY_PEER` plus `SSL_set1_host` before a single byte moves,
### so a certificate for the wrong name is a handshake *failure*
### carrying X509's own words ("hostname mismatch"), not a status
### somebody has to remember to ask for. SNI is always sent.
###
### An EOF without close_notify is reported as a plain EOF. Truncation
### matters to protocols that end a message by closing the socket;
### everything this package fronts (HTTP with Content-Length or
### chunked, RESP, SMTP replies) frames its own messages and survives
### a torn socket exactly as it did in the clear.

(import ./lib :as lib)

(def- chunk-size
  "One pump step: how much ciphertext is moved per BIO call, and the
  ceiling of one SSL_read_ex. A TLS record's plaintext tops out at
  16 KiB, so 32 KiB moves any record (and its framing) in one step."
  32768)

# -- contexts ------------------------------------------------------------

(defn context
  ``Build an SSL_CTX.

    :server?      accept side (test-support; keeps inbound TLS at the proxy) — default false
    :verify       check the peer's certificate chain (default true;
                  the :prod gate against false lives in the plugin)
    :ca-file      PEM bundle to trust instead of the library's default
    :ca-path      hashed CA directory to trust
    :min-version  :tls1.2 (default) or :tls1.3
    :cert :key    PEM chain and key files (the accept side must name
                  both)

  The context is long-lived and shared across connections; free it
  with `close-context` when it came from here and not from the
  plugin.``
  [&opt opts]
  (default opts {})
  (lib/ensure!)
  (def server? (get opts :server? false))
  (def ctx (lib/SSL_CTX_new (if server? (lib/TLS_server_method) (lib/TLS_client_method))))
  (unless ctx (errorf "SSL_CTX_new failed: %s" (or (lib/last-error) "no detail")))
  (def min-version (get opts :min-version :tls1.2))
  (lib/SSL_CTX_ctrl ctx lib/SSL-CTRL-SET-MIN-PROTO-VERSION
                    (case min-version
                      :tls1.2 lib/TLS1-2-VERSION
                      :tls1.3 lib/TLS1-3-VERSION
                      (errorf "[:tls :min-version] must be :tls1.2 or :tls1.3, got %q"
                              min-version))
                    nil)
  (def verify? (not (false? (get opts :verify true))))
  (lib/SSL_CTX_set_verify ctx (if (and verify? (not server?))
                                lib/SSL-VERIFY-PEER
                                lib/SSL-VERIFY-NONE)
                          nil)
  (when verify?
    (cond
      (or (opts :ca-file) (opts :ca-path))
      (unless (= 1 (lib/SSL_CTX_load_verify_locations ctx (opts :ca-file) (opts :ca-path)))
        (lib/SSL_CTX_free ctx)
        (errorf "tls: cannot load trust anchors (%s%s): %s"
                (or (opts :ca-file) "") (or (opts :ca-path) "")
                (or (lib/last-error) "no detail")))
      # the library's own trusted paths — a fact about the machine,
      # which `void tls info` prints rather than guesses at
      (lib/SSL_CTX_set_default_verify_paths ctx)))
  (when-let [cert (opts :cert)]
    (unless (= 1 (lib/SSL_CTX_use_certificate_chain_file ctx cert))
      (lib/SSL_CTX_free ctx)
      (errorf "tls: cannot load certificate chain %s: %s"
              cert (or (lib/last-error) "no detail"))))
  (when-let [key (opts :key)]
    (unless (= 1 (lib/SSL_CTX_use_PrivateKey_file ctx key lib/SSL-FILETYPE-PEM))
      (lib/SSL_CTX_free ctx)
      (errorf "tls: cannot load private key %s: %s"
              key (or (lib/last-error) "no detail"))))
  (when (and server? (not (and (opts :cert) (opts :key))))
    (lib/SSL_CTX_free ctx)
    (error "tls: an accept-side context needs :cert and :key"))
  ctx)

(defn close-context
  "Free a context built by `context`."
  [ctx]
  (when ctx (lib/SSL_CTX_free ctx))
  nil)

(var default-ctx
  ``The context `connect` uses when none is passed: built lazily with
  the defaults above (verify on, the library's trust anchors), and
  replaced by the plugin's :start with the configured one.``
  nil)

(defn default-context
  "The shared client context, building the lazy default on first use."
  []
  (unless default-ctx (set default-ctx (context)))
  default-ctx)

# -- the pump ------------------------------------------------------------

(defn- flush-out!
  "Move everything SSL put into its write BIO onto the raw stream —
  where the fiber may park, which is the point."
  [ts]
  (def scratch (ts :enc-buf))
  (while (pos? (int/to-number (lib/BIO_ctrl_pending (ts :wbio))))
    (def n (lib/BIO_read (ts :wbio) scratch chunk-size))
    (when (pos? n)
      (:write (ts :raw) (buffer/slice scratch 0 n))))
  nil)

(defn- feed-in!
  ``One raw read into SSL's read BIO. Returns false on EOF, true when
  bytes (or a spurious empty read) arrived; a timeout below propagates
  as the raw stream's own error.``
  [ts timeout]
  (def tmp (ts :raw-buf))
  (buffer/clear tmp)
  (def r (:read (ts :raw) chunk-size tmp timeout))
  (cond
    (nil? r) false
    (do (when (pos? (length tmp))
          (lib/BIO_write (ts :rbio) tmp (length tmp)))
        true)))

(defn- ssl-failure
  ``An SSL_ERROR_SSL as a message worth reading: when the cause is
  certificate verification, X509's own words come first ("hostname
  mismatch", "self-signed certificate"), the cipher-level error after.``
  [ts what]
  (def vr (int/to-number (lib/SSL_get_verify_result (ts :ssl))))
  (def detail (or (lib/last-error) "no detail"))
  (if (= lib/X509-V-OK vr)
    (string/format "tls %s failed (%s): %s" what (ts :peer-name) detail)
    (string/format "tls %s failed (%s): certificate verification: %s (%s)"
                   what (ts :peer-name)
                   (lib/X509_verify_cert_error_string vr) detail)))

(defn- handshake!
  [ts timeout]
  (var done false)
  (while (not done)
    (def r (lib/SSL_do_handshake (ts :ssl)))
    (flush-out! ts)
    (if (= 1 r)
      (set done true)
      (let [e (lib/SSL_get_error (ts :ssl) r)]
        (cond
          (= e lib/SSL-ERROR-WANT-READ)
          (unless (feed-in! ts timeout)
            (errorf "tls handshake failed (%s): the peer closed the connection"
                    (ts :peer-name)))

          (= e lib/SSL-ERROR-WANT-WRITE) nil # flushed above; go around

          (error (ssl-failure ts "handshake"))))))
  ts)

# -- the stream methods --------------------------------------------------

(defn- tls-read
  [ts n &opt buf timeout]
  (def out (or buf @""))
  (def plain (ts :plain-buf))
  (def outlen (ts :len-buf))
  (var result :pending)
  (while (= :pending result)
    (def want (min (max n 1) chunk-size))
    (def r (lib/SSL_read_ex (ts :ssl) plain want outlen))
    (if (= 1 r)
      (do
        (def got (int/to-number (ffi/read :uint64 outlen 0)))
        (buffer/push out (buffer/slice plain 0 got))
        (set result out))
      (let [e (lib/SSL_get_error (ts :ssl) r)]
        (cond
          (= e lib/SSL-ERROR-WANT-READ)
          (do
            # a handshake message may want out first (TLS 1.3 tickets,
            # renegotiation) — flush before parking on the socket
            (flush-out! ts)
            (unless (feed-in! ts timeout)
              # EOF underneath — with or without close_notify, the
              # session is over (module docstring)
              (set result nil)))

          (= e lib/SSL-ERROR-WANT-WRITE)
          (flush-out! ts)

          (= e lib/SSL-ERROR-ZERO-RETURN)
          (set result nil)

          (= e lib/SSL-ERROR-SYSCALL)
          (set result nil)

          (error (ssl-failure ts "read"))))))
  result)

(defn- tls-write
  [ts data &opt timeout]
  (def outlen (ts :len-buf))
  (var rest data)
  (while (pos? (length rest))
    (def r (lib/SSL_write_ex (ts :ssl) rest (length rest) outlen))
    (if (= 1 r)
      (do
        (flush-out! ts)
        (def wrote (int/to-number (ffi/read :uint64 outlen 0)))
        (set rest (if (< wrote (length rest)) (string/slice rest wrote) "")))
      (let [e (lib/SSL_get_error (ts :ssl) r)]
        (cond
          (= e lib/SSL-ERROR-WANT-READ)
          (do (flush-out! ts)
              (unless (feed-in! ts timeout)
                (errorf "tls write failed (%s): connection closed" (ts :peer-name))))

          (= e lib/SSL-ERROR-WANT-WRITE)
          (flush-out! ts)

          (error (ssl-failure ts "write"))))))
  nil)

(defn- tls-close
  [ts]
  (unless (ts :closed)
    (put ts :closed true)
    # close_notify is best effort: the peer may already be gone, and a
    # message that was accepted stays accepted whatever the socket
    # does now (the same stance void/mail's quit! takes)
    (protect (do (lib/SSL_shutdown (ts :ssl))
                 (flush-out! ts)))
    (protect (:close (ts :raw)))
    (lib/SSL_free (ts :ssl))
    (put ts :ssl nil))
  nil)

# -- public --------------------------------------------------------------

(defn- ip-literal?
  "Is this peer name an address rather than a DNS name? IPv6 has
  colons; IPv4 is digits and dots and nothing else."
  [host]
  (def s (string host))
  (or (string/find ":" s)
      (all |(or (and (>= $ (chr "0")) (<= $ (chr "9"))) (= $ (chr "."))) s)))

(defn wrap
  ``A TLS session over an open stream — `raw` is a janet stream or
  anything with the same `:read`/`:write`/`:close` methods. Options:

    :ctx      an SSL_CTX from `context` (default: the shared client
              context — verify on, the machine's trust anchors)
    :host     name to verify the peer's certificate against, and the
              SNI sent; the connect side must name it
    :accept?  take the server side of the handshake (test-support)
    :timeout  seconds for each socket read the handshake parks on
              (default 30 — a peer that says nothing must not park
              the fiber forever)

  The handshake runs before `wrap` returns, so a certificate problem
  is an error *here*, with X509's words in it. STARTTLS is this
  function on a socket that has already spoken: the protocol upgrade
  is the caller's, the session is ours.``
  [raw &opt opts]
  (default opts {})
  (lib/ensure!)
  (def accept? (get opts :accept? false))
  (def host (opts :host))
  (when (and (not accept?) (nil? host))
    (error "tls/wrap: the connect side needs :host — the name the peer's certificate is checked against"))
  (def ctx (or (opts :ctx) (default-context)))
  (def ssl (lib/SSL_new ctx))
  (unless ssl (errorf "SSL_new failed: %s" (or (lib/last-error) "no detail")))
  (def rbio (lib/BIO_new (lib/BIO_s_mem)))
  (def wbio (lib/BIO_new (lib/BIO_s_mem)))
  # the SSL owns both BIOs from here on: SSL_free frees them
  (lib/SSL_set_bio ssl rbio wbio)
  (if accept?
    (lib/SSL_set_accept_state ssl)
    (do
      (lib/SSL_set_connect_state ssl)
      (if (ip-literal? host)
        # an IP peer is pinned through the verify parameters —
        # SSL_set1_host checks DNS names, and SNI is not sent for an
        # address (RFC 6066 §3 names hostnames only)
        (unless (= 1 (lib/X509_VERIFY_PARAM_set1_ip_asc (lib/SSL_get0_param ssl) host))
          (lib/SSL_free ssl)
          (errorf "tls: %q is not an address a certificate can carry" host))
        (do
          (lib/SSL_ctrl ssl lib/SSL-CTRL-SET-TLSEXT-HOSTNAME
                        lib/TLSEXT-NAMETYPE-host-name host)
          (unless (= 1 (lib/SSL_set1_host ssl host))
            (lib/SSL_free ssl)
            (errorf "tls: SSL_set1_host %q failed" host))))))
  (def ts
    @{:ssl ssl
      :rbio rbio
      :wbio wbio
      :raw raw
      :peer-name (or host "accept side")
      :closed false
      # per-session scratch, allocated once: ciphertext out, ciphertext
      # in, plaintext out, and the size_t out-parameter
      :enc-buf (buffer/new-filled chunk-size)
      :raw-buf (buffer/new chunk-size)
      :plain-buf (buffer/new-filled chunk-size)
      :len-buf (buffer/new-filled 8)
      :read tls-read
      :write tls-write
      :close tls-close})
  (def [ok err] (protect (handshake! ts (get opts :timeout 30))))
  (unless ok
    (protect (:close raw))
    (lib/SSL_free ssl)
    (put ts :ssl nil)
    (put ts :closed true)
    (error err))
  ts)

(defn tls-version
  "The negotiated protocol of a wrapped stream (\"TLSv1.3\"), or nil."
  [ts]
  (when (ts :ssl) (lib/SSL_get_version (ts :ssl))))

(defn connect
  ``Open a socket and run the TLS handshake over it:

      (tls/connect "collector.example" "4318")

  `opts` are `wrap`'s; `:host` defaults to the host connected to —
  passing a different one is for a peer reached by IP whose
  certificate names something else. This function's shape (host, port,
  opts -> stream) is what the consumer seams hold.``
  [host port &opt opts]
  (default opts {})
  (def raw (net/connect host (string port) :stream))
  (wrap raw (merge {:host host} opts)))
