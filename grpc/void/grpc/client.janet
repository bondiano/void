### void/grpc/client — the other end of a Connect call.
###
###     (def orders (grpc/client "http://127.0.0.1:8080"))
###     (grpc/call orders :shop.orders/OrderService :GetOrder {:id "A-1"})
###
### It is void/http/client with the protocol on top, which means it
### inherits that module's decisions rather than making its own: one
### socket reused, no pool, no TLS (an `https:, ` URL is an error naming
### the relay), and a timeout that cancels a task instead of the caller's
### fiber.
###
### **An error is raised, not returned.** This is the one place void
### does that on purpose: `send!` hands back a 500 because a status is
### an answer, but an RPC failure is what happened *instead* of the
### response message, and every generated client in every language
### raises it. `(protect (grpc/call ...))` gives back the failure
### value — `{:void.grpc/code :not_found :message "…"}` — and
### `codes/failure` is what reads one out of anything else.
###
### **The GET form is opt-in.** `:get true` uses Connect's
### query-string form, and a method whose `.proto` did not say
### `idempotency_level = NO_SIDE_EFFECTS` refuses it here rather than
### at the server: it is the *declaration* that says the call is safe
### to repeat, and a client that decides otherwise is guessing on a
### question the service already answered.

(import spork/json)
(import spork/base64)
(import void/http/client :as http)
(import void/proto :as proto)
(import void/proto/descriptor :as pdesc)
(import ./codes :as codes)
(import ./connect :as connect)
(import ./service :as service)

(def encodings
  ``The two codecs a client can speak, by the name Connect calls them.
  The server's set is an extension point; a client's is what it was
  built with, so this is a table rather than a registry.``
  {:proto {:content-type "application/proto"
           :encoding "proto"
           :binary true
           :encode (fn [m v] (string (proto/encode m v)))
           :decode (fn [m bytes] (proto/decode m bytes))}
   :json {:content-type "application/json"
          :encoding "json"
          :binary false
          :encode (fn [m v] (proto/encode-json m v))
          :decode (fn [m bytes] (proto/decode-json m (string bytes)))}})

(defn client
  ``A Connect client against a base URL:

      (grpc/client "http://127.0.0.1:8080")
      (grpc/client "http://orders.internal" {:encoding :json
                                             :headers {"authorization" "Bearer …"}
                                             :timeout 2})

  opts: :encoding (:proto, the wire's default, or :json), :headers
  (sent with every call), :timeout (seconds, carried as
  Connect-Timeout-Ms so the *server* enforces it too).``
  [base-url &opt opts]
  (default opts {})
  (def encoding (get opts :encoding :proto))
  (unless (encodings encoding)
    (errorf "void/grpc: %q is not an encoding this client speaks (%s)"
            encoding (string/join (map string (sorted (keys encodings))) " ")))
  @{:url (string/trimr (string base-url) "/")
    :encoding encoding
    :headers (merge @{} (get opts :headers {}))
    :timeout (opts :timeout)})

(defn- method-of [svc-name method-name]
  (def d (pdesc/service! svc-name))
  (or (get-in d [:by-name method-name])
      (errorf "void/grpc: %q has no rpc %q (it has %s)"
              svc-name method-name
              (string/join (map |(string ($ :name)) (d :methods)) " ")))
  [d (get-in d [:by-name method-name])])

(defn- base64url [s]
  (string/replace-all "=" ""
                      (string/replace-all "/" "_"
                                          (string/replace-all "+" "-" (string s)))))

(defn- failure-of
  ``The failure a non-200 answer carries. A Connect error body names
  its own code; anything else (a proxy's 502 page, an HTML error from
  something in between) is read from the status, because a client that
  reported "unknown" for a 503 would send the caller looking in the
  wrong place.``
  [resp]
  (def body (string (or (resp :body) "")))
  (def [ok data] (protect (json/decode body)))
  (def code (when (and ok (dictionary? data) (get data "code"))
              (keyword (get data "code"))))
  (def message (if (and ok (dictionary? data) (get data "message"))
                 (string (get data "message"))
                 (string/format "the server answered %d" (resp :status))))
  (codes/error-value (if (and code (codes/code? code))
                       code
                       (codes/code-for-status (resp :status)))
                     message
                     (merge {:http/status (resp :status)}
                            (if (and ok (dictionary? data) (get data "details"))
                              {:details (get data "details")}
                              {}))))

(defn trailers
  ``The trailing metadata of an answered call: Connect carries a unary
  call's trailers as `Trailer-`-prefixed response headers, and this is
  them with the prefix taken off.``
  [resp]
  (tabseq [[k v] :pairs (get resp :headers {})
           :when (string/has-prefix? "trailer-" (string/ascii-lower (string k)))]
    (string/slice (string/ascii-lower (string k)) 8) v))

(defn call
  ``One unary call. Returns the response message; raises the RPC
  failure when the server answered with one.

      (grpc/call c :shop.orders/OrderService :GetOrder {:id "A-1"})
      (grpc/call c :shop.orders/OrderService :GetOrder {:id "A-1"} {:get true})

  opts: :headers (merged over the client's), :timeout (seconds, this
  call only), :get (Connect's query-string form — only for a method
  whose .proto declared it free of side effects), :full (return
  `{:message :headers :trailers}` instead of the bare message, for a
  caller that wants the response metadata).``
  [c svc-name method-name message &opt opts]
  (default opts {})
  (def [_ m] (method-of svc-name method-name))
  (when (or (m :client-streaming) (m :server-streaming))
    (errorf (string "void/grpc: %q.%s is a streaming method, and void speaks unary Connect "
                    "")
            svc-name (m :proto-name)))
  (def codec (encodings (c :encoding)))
  (def timeout (or (opts :timeout) (c :timeout)))
  (def body ((codec :encode) (m :input) message))
  (def headers
    (merge @{"connect-protocol-version" connect/protocol-version}
           (c :headers)
           (get opts :headers {})
           (if timeout
             {"connect-timeout-ms" (string (math/round (* 1000 timeout)))}
             {})))
  (def path (service/path-of (pdesc/proto-name svc-name) (m :proto-name)))
  (def request
    (if (opts :get)
      (do
        (unless (m :idempotent)
          (errorf (string "void/grpc: %q.%s did not declare `idempotency_level = "
                          "NO_SIDE_EFFECTS`, so it may not be called with GET — the .proto is "
                          "where that is decided")
                  svc-name (m :proto-name)))
        {:method :get
         :url (string (c :url) path)
         :query {"encoding" (codec :encoding)
                 "message" (if (codec :binary) (base64url (base64/encode body)) body)
                 "base64" (if (codec :binary) "1" "0")
                 "connect" "v1"}
         :headers (merge @{} headers {"content-type" nil})})
      {:method :post
       :url (string (c :url) path)
       :headers (merge @{"content-type" (codec :content-type)} headers)
       :body body}))
  (def [reached resp] (protect (http/request (if timeout
                                               (merge request {:timeout timeout})
                                               request))))
  (unless reached
    # nothing answered: a socket that would not open, a peer that hung
    # up, or this end's own deadline. A generated client reports those
    # as codes rather than as transport noise, because the caller's
    # question — "may I retry?" — has the same answer either way
    (def text (if (string? resp) resp (string/format "%q" resp)))
    (error (codes/error-value
             (if (some |(string/find $ text) ["timed out" "timeout" "deadline"])
               :deadline_exceeded
               :unavailable)
             text)))
  (unless (= 200 (resp :status))
    (error (failure-of resp)))
  (def value ((codec :decode) (m :output) (or (resp :body) "")))
  (if (opts :full)
    @{:message value :headers (get resp :headers @{}) :trailers (trailers resp)}
    value))
