(import ../test-support/paths)
(import spork/msg)
(import void/core/system :as system)
(import void/core/plugin :as plugin)
(import void/dev/netrepl :as netrepl)

# keep the socket path short: sun_path is ~104 bytes on macOS
(def sock (string "./.void-test-" (os/time) ".sock"))

# -- component start: server on a unix socket ----------------------------

(def inst (netrepl/start {:netrepl {:unix sock}}))
(assert (get inst :server) "server stream is kept for :stop")
(assert (= :socket (os/stat sock :mode)) "socket file exists")
(assert (= "rwx------" (get (os/stat sock) :permissions))
        "the socket is owner-only — it is an unauthenticated eval, and on a shared machine default permissions hand it to every local user")

# -- a client can connect and evaluate into the shared env ---------------

(defn roundtrip [code]
  (def s (net/connect :unix sock))
  (defer (:close s)
    (def send (msg/make-send s))
    (def recv (msg/make-recv s))
    (send "test-client")
    (send (string code "\n"))
    (var result nil)
    (ev/with-deadline 5
      (while (nil? result)
        (def m (recv))
        (when (nil? m) (error "server closed the connection"))
        # skip prompt messages ("name:line: "), keep the printed value
        (unless (string/has-suffix? ": " m)
          (set result (string/trim m)))))
    result))

(assert (= "5" (roundtrip "(+ 2 3)")) "netrepl evaluates code")

# the served env exposes the core modules and (boot)/(sys)
(assert (= "3" (roundtrip "(length [:a :b :c])")))
(plugin/bootstrap {:plugins []}) # make a current boot for (boot) to see
(assert (string/find "profile" (roundtrip "(keys (boot))"))
        "(boot) resolves the current boot inside the repl")
(assert (string/find "component" (roundtrip "(string (doc-format (get (dyn 'system/component) :doc)))"))
        "system/ prefix is merged into the repl env")

# definitions persist across connections (shared env)
(roundtrip "(def shared-thing 42)")
(assert (= "42" (roundtrip "shared-thing")) "the env is shared between sessions")

# -- stop closes the listener and unlinks the socket ---------------------

(netrepl/stop inst)
(assert (nil? (os/stat sock)) "socket file is removed on stop")
(def [ok _] (protect (net/connect :unix sock)))
(assert (not ok) "no more connections after stop")

(assert (= {:disabled true} (netrepl/start {:netrepl {:enabled false}}))
        "disabled netrepl starts nothing")

# -- what start refuses --------------------------------------------------

# a TCP host beyond loopback is a remote eval with no authentication
(def [remote-ok remote-err]
  (protect (netrepl/start {:netrepl {:host "0.0.0.0" :port 9365}})))
(assert (not remote-ok) "0.0.0.0 does not start")
(assert (string/find "allow-remote" (string remote-err))
        "and the refusal names the key that overrides it")

# a stale path is only ever deleted when it is a socket: a typo in
# :unix must not delete a source file
(def not-a-sock (string "./.void-test-file-" (os/time) ".janet"))
(spit not-a-sock "(def precious 1)\n")
(def [typo-ok typo-err] (protect (netrepl/start {:netrepl {:unix not-a-sock}})))
(assert (not typo-ok) "an existing non-socket file refuses the start")
(assert (string/find "not a socket" (string typo-err)))
(assert (os/stat not-a-sock) "and the file is still there")
(os/rm not-a-sock)

(print "netrepl-test: all assertions passed")
