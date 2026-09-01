# The stream half of ADR-0038, against a real socket: handshake,
# data both ways, records bigger than one TLS record, verification
# failing the handshake (not a status), STARTTLS-shaped mid-stream
# upgrade, and EOF. The server side is void/tls's own accept state
# over the committed test certificate — see test-support/tls-server.

(import ../test-support/paths)
(import void/tls/lib :as lib)
(import void/tls/stream :as stream)
(import ../test-support/tls-server :as tls-server)

(lib/load!)

(def trusting
  "A client context that trusts the suite's certificate."
  (stream/context {:ca-file tls-server/cert}))

# -- the library reports itself ------------------------------------------

(assert (lib/available?) "load! opened a libssl")
(def [major _ _] (lib/version))
(assert (>= major 1) "and it knows its version")

(when (= :macos (os/which))
  (each c (lib/candidates)
    (assert (string/has-prefix? "/" c)
            "the macOS candidate list is explicit paths only — a bare name aborts the process (ADR-0022 §3, pinned here the way crypto/lib pins it")))

# -- echo, both ways, across records -------------------------------------

(def echo (tls-server/start
            (fn [ts]
              (def buf @"")
              (while (:read ts 65536 buf 5)
                (:write ts buf)
                (buffer/clear buf)))))

(def c (stream/connect "127.0.0.1" (echo :port) {:ctx trusting :host "localhost" :timeout 5}))
(assert (= "TLSv1.3" (stream/tls-version c)) "openssl 3 negotiates 1.3 with itself")

(:write c "ping over tls")
(def got @"")
(:read c 8192 got 5)
(assert (= "ping over tls" (string got)) "a round trip carries the bytes")

# bigger than one 16 KiB TLS record: the pump reassembles what the
# record layer split
(def big (string/repeat "0123456789abcdef" 8192)) # 128 KiB
(:write c big)
(def back @"")
(while (< (length back) (length big))
  (assert (:read c 65536 back 5) "the echo keeps coming"))
(assert (= big (string back)) "128 KiB survives the record layer byte for byte")
(:close c)

# -- verification is the handshake ---------------------------------------

# the default trust anchors do not know the suite's self-signed cert
(def [ok1 err1] (protect (stream/connect "127.0.0.1" (echo :port)
                                         {:ctx (stream/context {}) :host "localhost"
                                          :timeout 5})))
(assert (not ok1) "an untrusted certificate fails the handshake itself")
(assert (string/find "certificate" (string err1)) "with X509's words in the error")

# a trusted cert for the wrong name is refused the same way
(def [ok2 err2] (protect (stream/connect "127.0.0.1" (echo :port)
                                         {:ctx trusting :host "wrong.example"
                                          :timeout 5})))
(assert (not ok2) "a name the certificate does not carry fails the handshake")
(assert (string/find "hostname mismatch" (string err2)) "and says why")

# an IP peer is verified against the certificate's IP entries — the
# suite's cert carries IP:127.0.0.1, so connecting by address with no
# :host override just works (the OTLP-collector-on-an-internal-IP case)
(def c-ip (stream/connect "127.0.0.1" (echo :port) {:ctx trusting :timeout 5}))
(:write c-ip "by address")
(def got-ip @"")
(:read c-ip 8192 got-ip 5)
(assert (= "by address" (string got-ip)))
(:close c-ip)

# verification off is a decision the context takes out loud
(def lax (stream/context {:verify false}))
(def c2 (stream/connect "127.0.0.1" (echo :port) {:ctx lax :host "localhost" :timeout 5}))
(:write c2 "unverified")
(def got2 @"")
(:read c2 8192 got2 5)
(assert (= "unverified" (string got2)))
(:close c2)
(stream/close-context lax)

# -- the connect side must name its peer ---------------------------------

(assert (not (first (protect (stream/wrap @{} {:ctx trusting}))))
        "wrap without :host on the connect side is an error, not a guess")

# -- STARTTLS shape: wrap a socket that has already spoken ----------------

(def plain-listener (net/listen "127.0.0.1" "0"))
(def [_ plain-port] (net/localname plain-listener))
(def starttls-ctx (stream/context {:server? true
                                   :cert tls-server/cert :key tls-server/key}))
(ev/go
  (fn starttls-server []
    (def conn (net/accept plain-listener))
    (def b @"")
    (:read conn 64 b 5)                       # "STARTTLS\n" in the clear
    (:write conn "OK\n")
    (def ts (stream/wrap conn {:ctx starttls-ctx :accept? true :timeout 5}))
    (def line @"")
    (:read ts 64 line 5)
    (:write ts (string "encrypted: " line))
    (:close ts)))

(def raw (net/connect "127.0.0.1" (string plain-port) :stream))
(:write raw "STARTTLS\n")
(def okbuf @"")
(:read raw 3 okbuf 5)
(assert (= "OK\n" (string okbuf)) "the plaintext half of the conversation happened")
(def upgraded (stream/wrap raw {:ctx trusting :host "localhost" :timeout 5}))
(:write upgraded "hello")
(def up-got @"")
(:read upgraded 64 up-got 5)
(assert (= "encrypted: hello" (string up-got))
        "the same socket carries TLS from here — wrap is STARTTLS's whole mechanism")
(:close upgraded)
(protect (:close plain-listener))
(stream/close-context starttls-ctx)

# -- EOF ------------------------------------------------------------------

(def closer (tls-server/start (fn [ts] nil)))   # handler returns; server closes
(def c3 (stream/connect "127.0.0.1" (closer :port) {:ctx trusting :host "localhost" :timeout 5}))
(assert (nil? (:read c3 8192 @"" 5)) "a peer that closed reads as EOF, like any stream")
(:close c3)
(:close c3)                                     # double close is quiet
(tls-server/stop closer)

(tls-server/stop echo)
(stream/close-context trusting)

(print "stream-test ok")
