# A real TLS server on a real loopback socket, for the suite: the
# accept side of void/tls's own stream over the committed test
# certificate (certs/README.md). Each connection is handed to `handler`
# as a wrapped stream — the suite's servers speak HTTP, RESP or plain
# echo through it, which is the point: the client under test must not
# be able to tell them from the clear-text ones.

(import void/tls/stream :as stream)

(def cert "test-support/certs/server-cert.pem")
(def key "test-support/certs/server-key.pem")

(defn start
  "Listen on an ephemeral loopback port; `handler` gets each
  connection as an accept-side TLS stream. Returns {:port :listener
  :ctx}; `stop` closes it."
  [handler]
  (def ctx (stream/context {:server? true :cert cert :key key}))
  (def listener (net/listen "127.0.0.1" "0"))
  (def [_ port] (net/localname listener))
  (ev/go
    (fn accept-loop []
      (while true
        (def [ok conn] (protect (net/accept listener)))
        (unless ok (break))
        (when conn
          (ev/go
            (fn connection []
              (def [wok ts] (protect (stream/wrap conn {:ctx ctx :accept? true
                                                        :timeout 5})))
              # a handshake the *test* made fail (no CA, wrong host)
              # ends here by design
              (when wok
                (def [hok herr] (protect (handler ts)))
                (unless hok
                  (eprintf "tls test server handler: %s" (string herr)))
                (protect (:close ts)))))))))
  {:port port :listener listener :ctx ctx})

(defn stop
  [srv]
  (protect (:close (srv :listener)))
  (stream/close-context (srv :ctx))
  nil)
