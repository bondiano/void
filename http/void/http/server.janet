### void/http/server — the HTTP/1.1 connection loop (ADR-0015,
### ADR-0010, ROADMAP 1.1).
###
### One fiber per connection on the ev loop; the loop is: read head
### (idle timeout while waiting between keep-alive requests, read
### timeout and max-header while one is arriving) -> read body
### (content-length or chunked, each against the route's effective
### max-body) -> dispatch -> write response -> keep-alive decision from
### the HTTP version and connection headers. Leftover bytes stay in the
### connection buffer for the next pipelined request. Responses stream:
### a bytes body writes with Content-Length, an iterable (fiber) body
### writes one chunk per element as it is produced — SSE rides on that.
### Graceful drain: stop closes the listener, idle connections drop
### immediately, in-flight requests get :drain-timeout to finish (their
### responses carry "connection: close"), stragglers are cut.
###
### The server knows nothing of routers or plugins: it takes a handler
### (fn [request] response) plus an optional :limits-fn giving the
### per-route [max-body timeout] before the body is read. Wiring lives
### in void/http/init.

(import ./wire :as wire)

(def default-config
  "Server limits and timeouts (config slice :http, SPEC §5.1)."
  {:host "127.0.0.1"
   :port 8080
   :max-header 8192
   :max-body 1048576
   :read-timeout 30
   :idle-timeout 75
   :drain-timeout 15
   :max-connections 1024})

(defn- now [] (os/clock :monotonic))

# -- low-level writes ----------------------------------------------------

(defn- write-simple
  "An owned early response (400/408/413/431/503...): always closes."
  [conn wbuf status &opt body headers]
  (def hs (merge @{"connection" "close"
                   "content-type" "text/plain; charset=utf-8"}
                 (or headers @{})))
  (buffer/clear wbuf)
  (wire/write-head wbuf status hs)
  (wire/write-body conn wbuf
                   (or body (string status " " (get wire/status-messages status "")))))

(defn- write-response
  "Write a handler response. HEAD and 1xx/204/304 stay bodyless (HEAD
  keeps the Content-Length a GET would have sent); every other empty
  body is framed as Content-Length: 0, so a keep-alive client knows the
  response is over."
  [conn wbuf req resp close?]
  (def status (get resp :status 200))
  (def headers (merge @{} (get resp :headers {})))
  (when close? (put headers "connection" "close"))
  (when (and (not close?) (= 0 (req :http-version)))
    (put headers "connection" "keep-alive"))
  (def body (resp :body))
  (def head? (= :head (req :method)))
  (def bodyless? (or (= 204 status) (= 304 status) (< status 200)))
  (buffer/clear wbuf)
  (wire/write-head wbuf status headers)
  (cond
    (or bodyless? (and head? (nil? body)))
    (do (buffer/push wbuf "\r\n")
        (:write conn wbuf)
        (buffer/clear wbuf))

    (and head? (bytes? body))
    (do (buffer/format wbuf "Content-Length: %d\r\n\r\n" (length body))
        (:write conn wbuf)
        (buffer/clear wbuf))

    head?
    (do (buffer/push wbuf "\r\n")
        (:write conn wbuf)
        (buffer/clear wbuf))

    # A response with no body still has to *say* that it has none.
    # Without a Content-Length (and without chunking) the body ends
    # when the connection does (RFC 9112 §6.3), so on a keep-alive
    # connection the client waits — for the idle timeout, or forever.
    # The bodyless statuses above must not carry the header; every
    # other empty response must, and `ring/redirect` is the one every
    # application meets first.
    (nil? body)
    (do (buffer/format wbuf "Content-Length: 0\r\n\r\n")
        (:write conn wbuf)
        (buffer/clear wbuf))

    (wire/write-body conn wbuf body)))

(defn serialize-response
  ``The exact bytes write-response would put on the socket, into a
  buffer — the inject path's fidelity contract (ADR-0017). Fiber
  bodies (chunked/SSE) are drained into the buffer as their frames.``
  [req resp &opt close?]
  (def out @"")
  (def sink @{:write (fn [_ data] (buffer/push out data) nil)})
  (write-response sink @"" req resp (truthy? close?))
  out)

# -- reads ---------------------------------------------------------------

(defn- read-more
  "Grow buf from the socket: buf on data, nil on EOF, :timeout."
  [conn buf timeout]
  (def [ok res] (protect (net/read conn 8192 buf timeout)))
  (cond
    ok res
    (string/find "timeout" (string res)) :timeout
    # a peer reset or a drain-time close of a parked socket reads as EOF
    (or (string/find "closed" (string res)) (string/find "reset" (string res))) nil
    (error res)))

(defn- consume!
  "Drop the first `n` bytes of buf (the finished request) so leftover
  pipelined bytes start the next one."
  [buf n]
  (if (>= n (length buf))
    (buffer/clear buf)
    (do
      (def rest (string/slice buf n))
      (buffer/clear buf)
      (buffer/push buf rest))))

(defn- header-str [headers name]
  (def v (get headers name))
  (if (indexed? v) (first v) v))

# markers thrown to abort one request/connection with an owned response
(defn- reject! [status &opt message]
  (error {:reject status :message message}))

(defn- read-head
  ``Fill buf until a full head is there. Returns the parsed head; throws
  {:reject ...} on limits/parse errors, {:hangup true} on EOF/idle
  timeout between requests.

  It also stamps `:arrived` on the connection info: the moment this
  request's first bytes were in the process's hands — already there
  for a pipelined one, the return of the first read for the rest. It
  is what void/obs measures its queue time from (SPEC §8.4's
  accept->handler), and it deliberately does not start at accept: a
  client that opens a connection and sends a second later (every
  browser preconnect) would otherwise report that second as this
  process's backlog.``
  [conn buf info opts]
  (var head nil)
  (var scanned 0)
  (put info :arrived (when (pos? (length buf)) (now)))
  (while (nil? head)
    (if-let [end (wire/head-end buf (max 0 (- scanned 3)))]
      (do
        (when (> end (opts :max-header))
          (reject! 431))
        (def parsed (wire/parse-request-head buf))
        (when (= :error parsed)
          (reject! 400 "malformed request head"))
        (set head parsed))
      (do
        (when (> (length buf) (opts :max-header))
          (reject! 431))
        (set scanned (length buf))
        # between requests an empty buffer waits on the idle timeout
        # and a hangup there is a normal keep-alive close, not an error
        (def waiting? (empty? buf))
        (put info :busy (not waiting?))
        (def r (read-more conn buf
                          (if waiting? (opts :idle-timeout) (opts :read-timeout))))
        (put info :busy true)
        (when (and (nil? (info :arrived)) (pos? (length buf)))
          (put info :arrived (now)))
        (cond
          (nil? r) (if waiting? (error {:hangup true}) (reject! 400))
          (= :timeout r) (if waiting? (error {:hangup true}) (reject! 408))))))
  head)

(defn- read-content-length-body [conn buf head len max-body opts]
  (when (> len max-body)
    (reject! 413))
  (def need (+ (head :head-size) len))
  (while (< (length buf) need)
    (def r (read-more conn buf (opts :read-timeout)))
    (cond
      (nil? r) (reject! 400 "body cut short")
      (= :timeout r) (reject! 408)))
  [(string/slice buf (head :head-size) need) need])

(defn- read-chunked-body [conn buf head max-body opts]
  (def body @"")
  (var pos (head :head-size))
  (defn want [n]
    (while (< (length buf) n)
      (def r (read-more conn buf (opts :read-timeout)))
      (cond
        (nil? r) (reject! 400 "chunked body cut short")
        (= :timeout r) (reject! 408))))
  (var done false)
  (while (not done)
    (def ch (wire/parse-chunk-head buf pos))
    (case ch
      nil (do
            (when (> (- (length buf) pos) (opts :max-header))
              (reject! 400 "oversized chunk-size line"))
            (want (inc (length buf))))
      :error (reject! 400 "malformed chunk framing")
      (do
        (def [size consumed] ch)
        (when (> (+ (length body) size) max-body)
          (reject! 413))
        (if (zero? size)
          (do
            # trailer section: either an immediate CRLF or trailer
            # lines ending in a blank one; bounded by max-header
            (def tstart (+ pos consumed))
            (var tend nil)
            (while (nil? tend)
              (want (+ tstart 2))
              (if (= "\r\n" (string/slice buf tstart (+ tstart 2)))
                (set tend (+ tstart 2))
                (if-let [e (string/find "\r\n\r\n" buf tstart)]
                  (set tend (+ e 4))
                  (do
                    (when (> (- (length buf) tstart) (opts :max-header))
                      (reject! 400 "oversized trailers"))
                    (want (inc (length buf)))))))
            (set pos tend)
            (set done true))
          (do
            (def data-start (+ pos consumed))
            (want (+ data-start size 2))
            (unless (= "\r\n" (string/slice buf (+ data-start size) (+ data-start size 2)))
              (reject! 400 "chunk not CRLF-terminated"))
            (buffer/push body (string/slice buf data-start (+ data-start size)))
            (set pos (+ data-start size 2)))))))
  [(string body) pos])

(defn- read-body
  "Read the request body per its framing headers. Returns [body
  consumed-total]. Rejects smuggling-shaped framing: transfer-encoding
  together with content-length, unknown codings, conflicting duplicate
  content-lengths (RFC 9112 §6)."
  [conn buf head max-body opts]
  (def headers (head :headers))
  (def te (get headers "transfer-encoding"))
  (def cl (get headers "content-length"))
  (cond
    (and te cl) (reject! 400 "both transfer-encoding and content-length")
    (indexed? te) (reject! 400 "multiple transfer-encoding headers")

    te
    (if (= "chunked" (string/ascii-lower (string/trim te)))
      (read-chunked-body conn buf head max-body opts)
      (reject! 501 "unsupported transfer-encoding"))

    cl
    (do
      (def vals (distinct (map string/trim (if (indexed? cl) cl [cl]))))
      (when (> (length vals) 1)
        (reject! 400 "conflicting content-length headers"))
      (def len (scan-number (first vals)))
      (unless (and len (>= len 0) (= len (math/trunc len)))
        (reject! 400 "malformed content-length"))
      (read-content-length-body conn buf head len max-body opts))

    [nil (head :head-size)]))

# -- one connection ------------------------------------------------------

(defn- keep-alive? [head resp state]
  (def conn-h (when-let [c (header-str (head :headers) "connection")]
                (string/ascii-lower c)))
  (and (not (state :draining))
       (not= "close" (when (dictionary? resp)
                       (get-in resp [:headers "connection"])))
       (if (= 1 (head :http-version))
         (not= "close" conn-h)
         (= "keep-alive" conn-h))))

(defn- build-request [conn head body info]
  (def raw (head :path))
  (def [path qs] (wire/split-path raw))
  @{:method (keyword (string/ascii-lower (head :method)))
    :path path
    :raw-path raw
    :query-string qs
    :query (or (wire/parse-query qs) @{})
    :headers (head :headers)
    :http-version (head :http-version)
    :body body
    :received (os/clock :monotonic)      # access-log duration base
    :arrived (get info :arrived)         # queue-time base (see read-head)
    :connection conn})

(defn- run-handler
  "Run the handler; with a :void.http/timeout it runs as its own task
  so the deadline cancels the handler, never the connection fiber —
  ev/with-deadline cancels the *root task*, and cancelling a long-lived
  loop fiber mid-ev-operation is exactly the upstream bug class of
  janet-lang/janet#1337/#1707 (see ADR-0015)."
  [handler req timeout &opt on-timeout]
  (if (nil? timeout)
    (handler req)
    (do
      (def sup (ev/chan 1))
      (def task (ev/go (fn handler-task [] (handler req)) nil sup))
      (ev/deadline timeout task task)
      (def [sig fib] (ev/take sup))
      (def value (fiber/last-value fib))
      (cond
        (= :ok sig) value
        (and (string? value) (string/find "deadline" value))
        (do
          # the :on-timeout lifecycle stage (ADR-0016): the handler
          # task was cancelled by its :void.http/timeout
          (when on-timeout (protect (on-timeout req)))
          {:status 503
           :headers @{"content-type" "text/plain; charset=utf-8"}
           :body "503 handler timeout"})
        (error value)))))

(defn- serve-connection [state conn opts]
  (def buf @"")
  (def wbuf @"")
  (def info @{:busy true})
  (put (state :conns) conn info)
  (defer (do
           (put (state :conns) conn nil)
           (protect (:close conn)))
    (def handler (opts :handler))
    (def limits-fn (opts :limits-fn))
    (var alive true)
    (while alive
      (def [ok err]
        (protect
          (do
            (def head (read-head conn buf info opts))
            # per-route limits are known before the body is read
            (def [path _] (wire/split-path (head :path)))
            (def method (keyword (string/ascii-lower (head :method))))
            (def limits (when limits-fn (limits-fn method path)))
            (def max-body (or (get limits :max-body) (opts :max-body)))

            # RFC 9110 §10.1.1: acknowledge Expect: 100-continue
            (when-let [expect (header-str (head :headers) "expect")]
              (when (and (= 1 (head :http-version))
                         (= "100-continue" (string/ascii-lower (string/trim expect))))
                (:write conn "HTTP/1.1 100 Continue\r\n\r\n")))

            (def [body consumed] (read-body conn buf head max-body opts))
            (def req (build-request conn head body info))
            (def resp (run-handler handler req (get limits :timeout)
                                   (opts :on-timeout)))
            (unless (and (dictionary? resp) (int? (resp :status)))
              (errorf "handler returned %q — expected a response table with :status"
                      resp))
            (def keep (and (keep-alive? head resp state)))
            (write-response conn wbuf req resp (not keep))
            # :on-response (ADR-0016): after the bytes hit the socket
            (when-let [notify (opts :on-response)]
              (protect (notify req resp)))
            (consume! buf consumed)
            (put info :busy false)
            (set alive keep))))
      (unless ok
        (set alive false)
        (cond
          (and (dictionary? err) (err :reject))
          (protect (write-simple conn wbuf (err :reject) (err :message)))

          (and (dictionary? err) (err :hangup))
          nil

          # handler leaks reach here only if wrap-panic is absent, and
          # broken pipes land here too — answer if the socket still can
          (do
            (eprintf "http connection error: %s"
                     (if (string? err) err (describe err)))
            (protect (write-simple conn wbuf 500))))))))

# -- lifecycle -----------------------------------------------------------

(defn start
  ``Start the server. Options (defaults in default-config):
    :handler         (fn [request] response) — required; compose 404s,
                     panic guards and routing before handing it here
    :limits-fn       (fn [method path] {:max-body :timeout}) — the
                     route's effective limits, consulted before the
                     body is read
    :host :port      listen address (port "0" for an ephemeral one)
    :max-header :max-body :read-timeout :idle-timeout
    :max-connections over the limit new connections get an owned 503

  Returns the server instance; (server/stop inst) drains it. The
  actual bound port is under :port (useful with "0").``
  [options]
  (def opts (merge default-config options))
  (unless (function? (opts :handler))
    (error "server/start requires a :handler function"))
  (def listener (net/listen (opts :host) (string (opts :port))))
  (def state @{:conns @{} :draining false})
  (def [_ actual-port] (net/localname listener))
  (def accept-fiber
    (ev/go
      (fn accept-loop []
        (while true
          (def [ok conn] (protect (net/accept listener)))
          (unless ok (break))
          # janet 1.41 quirk: a closing listener wakes the parked accept
          # with a nil "connection" first — only the NEXT accept errors
          # with "stream is closed". Skip the nil (see ADR-0015 and
          # scripts/janet-repro/accept-spurious-nil.janet)
          (when conn
            (if (>= (length (state :conns)) (opts :max-connections))
              (ev/go (fn overloaded []
                       (defer (protect (:close conn))
                         (protect (write-simple conn @"" 503)))))
              (ev/go (fn connection [] (serve-connection state conn opts)))))))))
  @{:listener listener
    :state state
    :accept-fiber accept-fiber
    :host (opts :host)
    :port actual-port
    :config opts})

(defn connections
  "Live connection count."
  [inst]
  (length (get-in inst [:state :conns])))

(defn draining?
  [inst]
  (get-in inst [:state :draining]))

(defn stop
  ``Graceful drain (ADR-0015): close the listener so nothing new is
  accepted, drop idle keep-alive connections, give in-flight requests
  up to :drain-timeout seconds (their responses already carry
  "connection: close" because :draining flips first), then cut the
  stragglers. Returns the instance.``
  [inst &opt drain-timeout]
  (def state (inst :state))
  (def timeout (or drain-timeout (get-in inst [:config :drain-timeout])))
  (put state :draining true)
  (protect (:close (inst :listener)))
  (each conn (keys (state :conns))
    (unless (get-in state [:conns conn :busy])
      (protect (:close conn))))
  (def deadline (+ (now) timeout))
  (while (and (pos? (length (state :conns))) (< (now) deadline))
    (ev/sleep 0.02))
  (each conn (keys (state :conns))
    (protect (:close conn)))
  (put state :conns @{})
  inst)
