### void/http/client — the HTTP/1.1 client (SPEC.md §5.1, ADR-0015,
### ROADMAP 4.1).
###
### The other direction of the kernel. void has had a server since
### wave 1 and no client at all: `void/obs` could put a `traceparent`
### into an outgoing request (`trace/inject!`) but had nothing to make
### one with, and the OTLP exporter of wave 4 needs exactly this —
### a POST to a collector, from inside the ev loop, without a thread.
###
### **It is the server's wire module read backwards.** Heads are
### formatted and parsed by `void/http/wire` — the same PEG that reads
### a response in the server's tests reads one here, and the chunked
### framing is the one the server writes. A second HTTP implementation
### in the same package would be two dialects of one protocol.
###
### **What it deliberately does not do.**
###
###   TLS         there is none (ADR-0010): an `https://` URL is an
###               error with a text that says what to do instead —
###               a relay, a sidecar or a proxy next to the process,
###               the same answer void/mail gives for SMTP.
###   redirects   a 30x comes back as a 30x. Following one is a policy
###               (does a POST become a GET? is the new host allowed?)
###               and a client that guesses it is a client that
###               surprises somebody in production.
###   cookies     a jar is session state, and session state belongs to
###               whoever has a session.
###   retries     one, and only in the case where a retry is not a
###               decision: a *reused* keep-alive connection that the
###               peer had already closed. Every other failure comes
###               back to the caller, who is the only one who knows
###               whether the request was safe to repeat.
###
### **One connection, reused, and nothing pooled.** `open` returns a
### client holding at most one socket to one host; `send!` reuses it
### and reopens it when the peer went away. That is what a telemetry
### exporter, a webhook sender or an RPC call needs, and it is a
### fiber's worth of state rather than a pool's. A caller that wants
### concurrency opens more clients — a pool over sockets is
### `void/db/pool`'s job, and it is not free.
###
### **Timeouts cancel a task, never the caller's fiber.** A deadline
### around a socket operation in the calling fiber is the upstream bug
### class ADR-0015 names (janet-lang/janet#1337); so a request with a
### `:timeout` runs as its own task and the deadline cancels *that*,
### which is the same shape `run-handler` uses on the server side.
###
### The counters this module keeps are read by void/obs through
### `stats` — the public-function seam every instrumentation in
### `void/obs/instrument` uses, so the client stays free of any
### knowledge that observability exists.

(import ./wire :as wire)

(def default-ports
  "Port a scheme implies when the URL does not name one."
  {"http" "80"})

(def user-agent
  "What this client calls itself. A server that is about to rate-limit
  somebody deserves to know who."
  "void-http/0.0.1")

(def defaults
  ``Defaults of a client:

    :timeout          seconds for one whole request/response exchange
    :connect-timeout  seconds to establish the socket
    :max-body         bytes of response body accepted before the
                      exchange is refused — a client without a limit
                      is a memory bug waiting for a server that
                      streams forever
    :keep-alive       reuse the socket between requests``
  {:timeout 10
   :connect-timeout 5
   :max-body (* 8 1024 1024)
   :keep-alive true})

# -- what the client counts ----------------------------------------------
#
# Plain integers in one table, read by `stats`. void/obs points its
# metrics at that function (void/obs/instrument) the way it does at
# void/db/pool's — the client itself knows nothing about metrics.

(def- counters
  @{:requests 0 :responses 0 :failures 0 :timeouts 0
    :connects 0 :reconnects 0 :bytes-out 0 :bytes-in 0 :request-us 0})

(defn stats
  "What this process's HTTP clients have done: requests, responses,
  failures, connections opened, sockets reopened under a reused
  keep-alive, bytes each way and total time in microseconds."
  []
  (table/to-struct counters))

(defn reset-stats!
  "Zero the counters — for a test that asserts on them."
  []
  (eachk k counters (put counters k 0))
  nil)

(defn- count! [key n]
  (put counters key (+ (get counters key 0) n)))

# -- urls ----------------------------------------------------------------

(defn parse-url
  ``Split an absolute URL into `{:scheme :host :port :target
  :userinfo}`. `:port` is a string (what `net/connect` takes) and
  `:target` is the request target — path and query, `/` when the URL
  has none.

  An `https://` URL is refused here rather than at connect time: void
  has no TLS (ADR-0010), and the failure should name the deployment
  shape that replaces it instead of arriving as a protocol error from
  a server that got a plaintext request.``
  [url]
  (def s (string url))
  (def sep (string/find "://" s))
  (unless sep
    (errorf "http client: %s is not an absolute URL (want http://host[:port]/path)" s))
  (def scheme (string/ascii-lower (string/slice s 0 sep)))
  (when (= "https" scheme)
    (errorf (string "http client: %s — void speaks no TLS (ADR-0010). "
                    "Put the TLS at a relay, a sidecar or a proxy next to the "
                    "process and point this at it over http://") s))
  (unless (get default-ports scheme)
    (errorf "http client: unsupported scheme %s:// (only http:// — ADR-0010)" scheme))
  (def rest (string/slice s (+ sep 3)))
  (def slash (string/find "/" rest))
  (def authority (if slash (string/slice rest 0 slash) rest))
  (def target (if slash (string/slice rest slash) "/"))
  (def at (string/find "@" authority))
  (def userinfo (when at (string/slice authority 0 at)))
  (def hostport (if at (string/slice authority (inc at)) authority))
  (when (empty? hostport)
    (errorf "http client: %s names no host" s))
  (var host hostport)
  (var port nil)
  (if (string/has-prefix? "[" hostport)
    # IPv6 literal: [::1]:4318
    (let [close (or (string/find "]" hostport)
                    (errorf "http client: %s has an unterminated IPv6 host" s))]
      (set host (string/slice hostport 1 close))
      (when (< (+ close 1) (length hostport))
        (set port (string/slice hostport (+ close 2)))))
    (when-let [colon (string/find ":" hostport)]
      (set host (string/slice hostport 0 colon))
      (set port (string/slice hostport (inc colon)))))
  {:scheme scheme
   :host host
   :port (if (or (nil? port) (empty? port)) (get default-ports scheme) port)
   :target target
   :userinfo userinfo})

(defn- authority-str [host port scheme]
  (def implied (get default-ports scheme))
  (def h (if (string/find ":" host) (string "[" host "]") host))
  (if (= (string port) implied) h (string h ":" port)))

# -- writing a request ---------------------------------------------------

(defn- lower-keys
  "Header names as the wire wants to compare them: lowercase strings."
  [headers]
  (def out @{})
  (eachp [k v] (or headers {})
    (put out (string/ascii-lower (string k)) v))
  out)

(defn- method-str [method]
  (string/ascii-upper (string (if (keyword? method) method (or method :get)))))

(defn format-request
  ``The bytes of one request: head, blank line and body. Pure — a test
  asserts on the string, and `send!` is the only thing that writes
  it.

  `Host` is added when the caller did not, `Content-Length` whenever
  there is a body (a length is always known here: bodies are byte
  sequences, and a client that chunked its own request body would
  need a server that accepts it), and `Connection: close` when the
  exchange is not keep-alive.``
  [req]
  (def method (method-str (req :method)))
  (def target (or (req :target) "/"))
  (def headers (lower-keys (req :headers)))
  (def body (req :body))
  (def buf (buffer/new 256))
  (buffer/format buf "%s %s HTTP/1.1\r\n" method target)
  (buffer/format buf "host: %s\r\n"
                 (or (get headers "host") (req :authority) "localhost"))
  (unless (get headers "user-agent")
    (buffer/format buf "user-agent: %s\r\n" (get req :user-agent user-agent)))
  (eachp [k v] headers
    (unless (or (= k "host") (= k "content-length") (= k "connection"))
      (if (indexed? v)
        (each ve v (buffer/format buf "%s: %V\r\n" k ve))
        (buffer/format buf "%s: %V\r\n" k v))))
  (when body
    (buffer/format buf "content-length: %d\r\n" (length body)))
  (buffer/format buf "connection: %s\r\n" (if (req :close) "close" "keep-alive"))
  (buffer/push-string buf "\r\n")
  (when body (buffer/push buf body))
  buf)

# -- reading a response --------------------------------------------------

(defn- read-more!
  "Grow buf from the socket. Returns buf, or nil at EOF; throws
  :void.http/timeout on a read timeout."
  [conn buf timeout]
  (def [ok res] (protect (net/read conn 8192 buf timeout)))
  (cond
    ok res
    (string/find "timeout" (string res)) (error {:void.http/timeout true})
    (or (string/find "closed" (string res))
        (string/find "reset" (string res))
        (string/find "broken" (string res))) nil
    (error res)))

(defn- header-str [headers name]
  (def v (get headers name))
  (if (indexed? v) (first v) v))

(defn- bodyless? [status method]
  (or (= "HEAD" method)
      (= 204 status)
      (= 304 status)
      (and (>= status 100) (< status 200))))

(defn- read-head! [conn buf timeout]
  (var head (wire/parse-response-head buf))
  (while (nil? head)
    (unless (read-more! conn buf timeout)
      (error {:void.http/closed true
              :message "connection closed before a response head"}))
    (set head (wire/parse-response-head buf)))
  (when (= :error head)
    (error {:void.http/protocol true :message "malformed response head"}))
  head)

(defn- read-sized! [conn buf head len max-body timeout]
  (when (> len max-body)
    (error {:void.http/too-large true
            :message (string/format "response body of %d bytes is past :max-body" len)}))
  (def need (+ (head :head-size) len))
  (while (< (length buf) need)
    (unless (read-more! conn buf timeout)
      (error {:void.http/closed true :message "response body cut short"})))
  [(string/slice buf (head :head-size) need) need])

(defn- read-chunked! [conn buf head max-body timeout]
  (def body @"")
  (var pos (head :head-size))
  (defn want [n]
    (while (< (length buf) n)
      (unless (read-more! conn buf timeout)
        (error {:void.http/closed true :message "chunked response cut short"}))))
  (var done false)
  (while (not done)
    (def ch (wire/parse-chunk-head buf pos))
    (case ch
      nil (want (inc (length buf)))
      :error (error {:void.http/protocol true :message "malformed chunk framing"})
      (let [[size consumed] ch]
        (when (> (+ (length body) size) max-body)
          (error {:void.http/too-large true
                  :message "chunked response is past :max-body"}))
        (if (zero? size)
          (do
            # trailer section: either an immediate CRLF or trailer
            # lines ending in a blank one (the server's own reader,
            # read from this side)
            (def tstart (+ pos consumed))
            (var tend nil)
            (while (nil? tend)
              (want (+ tstart 2))
              (if (= "\r\n" (string/slice buf tstart (+ tstart 2)))
                (set tend (+ tstart 2))
                (if-let [e (string/find "\r\n\r\n" buf tstart)]
                  (set tend (+ e 4))
                  (want (inc (length buf))))))
            (set pos tend)
            (set done true))
          (do
            (def data-start (+ pos consumed))
            (want (+ data-start size 2))
            (unless (= "\r\n" (string/slice buf (+ data-start size) (+ data-start size 2)))
              (error {:void.http/protocol true :message "chunk not CRLF-terminated"}))
            (buffer/push body (string/slice buf data-start (+ data-start size)))
            (set pos (+ data-start size 2)))))))
  [(string body) pos])

(defn- read-to-eof! [conn buf head max-body timeout]
  (while (read-more! conn buf timeout)
    (when (> (- (length buf) (head :head-size)) max-body)
      (error {:void.http/too-large true
              :message "response body is past :max-body"})))
  [(string/slice buf (head :head-size)) (length buf)])

(defn- read-response! [conn buf opts method]
  (def timeout (opts :read-timeout))
  (def max-body (get opts :max-body (defaults :max-body)))
  (def head (read-head! conn buf timeout))
  (def headers (head :headers))
  (def status (head :status))
  (def te (header-str headers "transfer-encoding"))
  (def cl (header-str headers "content-length"))
  (def [body consumed]
    (cond
      (bodyless? status method) [nil (head :head-size)]
      (and te (string/find "chunked" (string/ascii-lower te)))
      (read-chunked! conn buf head max-body timeout)
      cl (read-sized! conn buf head (scan-number cl) max-body timeout)
      # no framing at all: the body is what arrives until the peer
      # closes, and the socket cannot be reused afterwards
      (read-to-eof! conn buf head max-body timeout)))
  (def rest (string/slice buf consumed))
  (buffer/clear buf)
  (buffer/push buf rest)
  (def conn-header (string/ascii-lower (or (header-str headers "connection") "")))
  @{:status status
    :message (head :message)
    :http-version (head :http-version)
    :headers headers
    :body body
    :bytes consumed
    # what the *peer* said about the socket, which is what decides
    # whether the next request may reuse it
    :close (or (string/find "close" conn-header)
               (and (= 0 (head :http-version))
                    (not (string/find "keep-alive" conn-header)))
               (and (nil? cl) (nil? te) (not (bodyless? status method)))
               false)})

# -- the client ----------------------------------------------------------

(defn open
  ``A client for one host. Options: `:url` (any URL on the host — its
  scheme, host and port are what is kept), or `:host` and `:port`
  directly, plus the `defaults` above and `:headers` sent with every
  request.

  Opening allocates nothing on the network: the socket is opened by
  the first `send!` and reopened whenever the peer closed it.``
  [&opt opts]
  (default opts {})
  (def u (if-let [url (opts :url)] (parse-url url) {}))
  (def host (or (opts :host) (u :host)
                (error "http client: open needs a :url or a :host")))
  (def scheme (or (u :scheme) "http"))
  (def port (string (or (opts :port) (u :port) (get default-ports scheme))))
  @{:host host
    :port port
    :scheme scheme
    :authority (authority-str host port scheme)
    :headers (get opts :headers {})
    :timeout (get opts :timeout (defaults :timeout))
    :connect-timeout (get opts :connect-timeout (defaults :connect-timeout))
    :max-body (get opts :max-body (defaults :max-body))
    :keep-alive (get opts :keep-alive (defaults :keep-alive))
    :conn nil
    :buf @""})

(defn close!
  "Close the client's socket, if it has one open. A client stays
  usable — the next `send!` opens a new one."
  [client]
  (when-let [conn (client :conn)]
    (put client :conn nil)
    (protect (:close conn)))
  (buffer/clear (client :buf))
  nil)

(defn- connect! [client]
  (def [ok conn] (protect (net/connect (client :host) (client :port) :stream)))
  (unless ok
    (count! :failures 1)
    (errorf "http client: cannot connect to %s — %s"
            (client :authority) (if (string? conn) conn (describe conn))))
  (count! :connects 1)
  (put client :conn conn)
  (buffer/clear (client :buf))
  conn)

(defn- with-deadline*
  ``Run `f` as its own task under a deadline: the cancellation lands
  on the task and not on the caller's fiber (see the module
  docstring). Without a timeout there is no task and no channel — a
  client used inside a request should not pay for a supervisor it did
  not ask for.``
  [seconds f]
  (if (nil? seconds)
    (f)
    (let [sup (ev/chan 1)
          task (ev/go (fn client-task [] (f)) nil sup)]
      (ev/deadline seconds task task)
      (def [sig fib] (ev/take sup))
      (def value (fiber/last-value fib))
      (cond
        (= :ok sig) value
        (and (string? value) (string/find "deadline" value))
        (error {:void.http/timeout true})
        (error value)))))

(defn- write! [conn bytes]
  (def [ok err] (protect (:write conn bytes)))
  (unless ok
    # a peer that closed the socket while it was parked reads as a
    # write failure here — the request reached nobody, which is what
    # `send!` needs to know to reopen and repeat it
    (if (or (string/find "closed" (string err))
            (string/find "reset" (string err))
            (string/find "broken" (string err))
            (string/find "pipe" (string err)))
      (error {:void.http/closed true :message "connection closed while sending"})
      (error err)))
  nil)

(defn- exchange! [client bytes method]
  (def conn (or (client :conn) (connect! client)))
  (write! conn bytes)
  (count! :bytes-out (length bytes))
  (def resp (read-response! conn (client :buf)
                            {:read-timeout (client :timeout)
                             :max-body (client :max-body)}
                            method))
  (count! :bytes-in (resp :bytes))
  resp)

(defn send!
  ``Send one request on this client and return the response:

      (client/send! c {:method :post :target "/v1/traces"
                       :headers {"content-type" "application/json"}
                       :body payload})

  The response is `{:status :message :headers :body :http-version}`,
  whatever the status: a 500 is an answer, not an error. Errors are
  what happened *instead* of an answer — no connection, a timeout, a
  body past `:max-body`, framing the peer got wrong.

  A socket the peer closed while it was idle is the one failure this
  retries by itself, once, because it is not a decision: the request
  never reached anybody.``
  [client req]
  (def method (method-str (req :method)))
  (def close? (or (req :close) (not (client :keep-alive))))
  (def headers (merge (lower-keys (client :headers)) (lower-keys (req :headers))))
  (def bytes (format-request {:method method
                              :target (or (req :target) (req :path) "/")
                              :headers headers
                              :body (req :body)
                              :authority (client :authority)
                              :close close?}))
  (def started (os/clock :monotonic))
  (count! :requests 1)
  (var attempt 0)
  (var out nil)
  (while (nil? out)
    (def reused (truthy? (client :conn)))
    (def [ok res] (protect (with-deadline* (client :timeout)
                                           (fn exchange [] (exchange! client bytes method)))))
    (cond
      ok
      (do
        (set out res)
        (count! :responses 1)
        (count! :request-us (math/round (* 1000000 (- (os/clock :monotonic) started))))
        (when (or close? (res :close)) (close! client)))

      # a keep-alive socket the peer had already closed: the request
      # never reached anybody, so sending it again is not a retry of
      # anything that happened
      (and reused (zero? attempt) (dictionary? res) (res :void.http/closed))
      (do
        (++ attempt)
        (close! client)
        (count! :reconnects 1))

      (do
        (close! client)
        (count! :failures 1)
        (when (and (dictionary? res) (res :void.http/timeout))
          (count! :timeouts 1))
        (error
          (cond
            (and (dictionary? res) (res :void.http/timeout))
            (string/format "http client: %s %s to %s timed out after %q s"
                           method (or (req :target) "/") (client :authority)
                           (client :timeout))
            (and (dictionary? res) (res :message))
            (string/format "http client: %s %s to %s — %s"
                           method (or (req :target) "/") (client :authority)
                           (res :message))
            res)))))
  out)

(defn request
  ``One request to an absolute URL, on a connection of its own:

      (client/request {:method :post :url "http://127.0.0.1:4318/v1/traces"
                       :headers {"content-type" "application/json"}
                       :body payload})

  The connection is opened, used and closed — for anything repeated,
  `open` a client and `send!` on it.``
  [opts]
  (def u (parse-url (or (opts :url) (error "http client: request needs a :url"))))
  (def client (open (merge opts {:host (u :host) :port (u :port) :keep-alive false})))
  (defer (close! client)
    (send! client (merge opts {:target (u :target) :close true}))))

# `get` and `post` shadow the core `get` inside this module, which is
# why they are the last two things in the file: everything above uses
# the real one. At a call site they read the way they should —
# `(client/get url)`.

(defn get
  "GET an absolute URL — `request` with the method filled in."
  [url &opt opts]
  (request (merge (or opts {}) {:url url :method :get})))

(defn post
  "POST a body to an absolute URL."
  [url body &opt opts]
  (request (merge (or opts {}) {:url url :method :post :body body})))
