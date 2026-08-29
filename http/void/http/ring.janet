### void/http/ring — the Ring model helpers (SPEC.md §5.1, ROADMAP 1.1).
###
### Request and response are plain tables, nothing more: a handler is
### (fn [request] response), middleware wraps handlers. Response shape:
###   {:status 200 :headers {"content-type" "text/html"} :body <body>}
### where :body is bytes (Content-Length), nil (no body), or any
### iterable — including a fiber — streamed as chunked transfer coding
### (that is also how SSE flows). Header names are lowercase strings on
### both sides; a repeated header (set-cookie) is an array of values.
### One more key ends HTTP instead of framing it: `:void.http/upgrade`
### (see `upgrade` below) hands the socket to another protocol.
### This module only builds and reads tables — no I/O, no globals.

(import ./wire :as wire)

# -- responses -----------------------------------------------------------

(defn response
  "A response table: status, optional body and headers."
  [status &opt body headers]
  @{:status status
    :body body
    :headers (if headers (merge-into @{} headers) @{})})

(defn header
  ``Set a response header (lowercase names by convention). Setting a
  header that is already present replaces it; `header-add` accumulates
  instead. Returns the response for threading.``
  [resp name value]
  (put (resp :headers) name value)
  resp)

(defn header-add
  "Add one more value to a response header (set-cookie and friends):
  the value becomes an array on the second addition."
  [resp name value]
  (def h (resp :headers))
  (def prev (get h name))
  (put h name
       (cond
         (nil? prev) value
         (indexed? prev) (array/push (array ;prev) value)
         @[prev value]))
  resp)

(defn content-type
  "Set the content-type response header."
  [resp mime]
  (header resp "content-type" mime))

(defn text
  "A text/plain response."
  [status body]
  (response status body @{"content-type" "text/plain; charset=utf-8"}))

(defn html
  "A text/html response."
  [status body]
  (response status body @{"content-type" "text/html; charset=utf-8"}))

(defn redirect
  "A redirect response (302 by default)."
  [location &opt status]
  (default status 302)
  (response status nil @{"location" location}))

(defn not-found
  "The default 404."
  [&opt body]
  (text 404 (or body "not found")))

(defn upgrade
  ``A protocol-upgrade response: the head goes out as an ordinary
  response (101 by default, with `headers`), and then `take-over` —
  `(fn [connection leftover-bytes])` — owns the socket until it
  returns, at which point the connection is closed.

      (ring/upgrade @{"upgrade" "websocket"
                      "connection" "Upgrade"
                      "sec-websocket-accept" accept}
                    (fn [conn rest] (ws-loop conn rest)))

  `leftover-bytes` are the bytes that had already arrived behind the
  request head — a client may send its first frame in the same packet
  as the handshake, and dropping them would lose a message before the
  new protocol had said a word.

  This is the whole seam void/ws needs from the kernel: HTTP ends on
  that socket, no keep-alive decision is taken and nothing else is
  written. Everything before it — routing, sessions, authentication,
  authorization, route metadata — happened the way it does for any
  other route, because a handler that answers this is an ordinary
  handler.``
  [headers take-over &opt status]
  (unless (function? take-over)
    (errorf "ring/upgrade needs a (fn [connection leftover]) to hand the socket to, got %q"
            take-over))
  (def resp (response (or status 101) nil headers))
  (put resp :void.http/upgrade take-over)
  resp)

# -- request access ------------------------------------------------------

(defn request-header
  ``One request header value by lowercase name. Repeated headers arrive
  as arrays (see wire/parse-request-head); this returns the first value
  — reach into (req :headers) for the full array.``
  [req name]
  (def v (get-in req [:headers name]))
  (if (indexed? v) (first v) v))

(defn cookies
  "The request cookies as a name -> value table, parsed once and
  memoized in (req :cookies)."
  [req]
  (or (req :cookies)
      (let [c (wire/parse-cookies (request-header req "cookie"))]
        (put req :cookies c)
        c)))

# -- set-cookie ----------------------------------------------------------

(def- same-site-values {:strict "Strict" :lax "Lax" :none "None"})

(defn cookie-str
  ``Format one set-cookie header value. Options:
    :path :domain :max-age :expires (an HTTP date string)
    :secure :http-only (booleans) :same-site (:strict :lax :none)``
  [name value &opt opts]
  (default opts {})
  (def out @"")
  (buffer/format out "%s=%s" (string name) (wire/url-encode (string value)))
  (when-let [p (opts :path)] (buffer/format out "; Path=%s" p))
  (when-let [d (opts :domain)] (buffer/format out "; Domain=%s" d))
  (when-let [a (opts :max-age)] (buffer/format out "; Max-Age=%d" a))
  (when-let [e (opts :expires)] (buffer/format out "; Expires=%s" e))
  (when (opts :secure) (buffer/push out "; Secure"))
  (when (opts :http-only) (buffer/push out "; HttpOnly"))
  (when-let [s (opts :same-site)]
    (buffer/format out "; SameSite=%s"
                   (or (same-site-values s)
                       (errorf ":same-site must be :strict, :lax or :none, got %q" s))))
  (string out))

(defn set-cookie
  "Add a set-cookie header to a response (see cookie-str for options)."
  [resp name value &opt opts]
  (header-add resp "set-cookie" (cookie-str name value opts)))

(defn delete-cookie
  "Expire a cookie on the client."
  [resp name &opt opts]
  (set-cookie resp name ""
              (merge {:max-age 0} (or opts {}))))

# -- server-sent events (SPEC §5.1: SSE is part of the contract) ---------

(defn sse-event
  ``Format one SSE event:

      (sse-event "tick")
      (sse-event {:event "update" :data "line1\nline2" :id "42" :retry 5000})

  Multi-line :data becomes one data: field per line, per the spec.``
  [ev]
  (def {:event event :data data :id id :retry retry}
    (if (dictionary? ev) ev {:data ev}))
  (def out @"")
  (when id (buffer/format out "id: %s\n" (string id)))
  (when event (buffer/format out "event: %s\n" (string event)))
  (when retry (buffer/format out "retry: %d\n" retry))
  (when data
    (each line (string/split "\n" (string data))
      (buffer/format out "data: %s\n" line)))
  (buffer/push out "\n")
  (string out))

(defn sse
  ``An SSE response streaming a fiber (or any iterable) of events; each
  yielded value goes through sse-event, so both plain strings and
  {:event :data :id :retry} tables work:

      (ring/sse (coro (for i 0 10 (yield {:data (string i)}) (ev/sleep 1))))

  The connection streams each event as its own chunk — the server
  writes a chunk per yield, so events flush as they are produced.``
  [events &opt headers]
  (response 200
            (if (fiber? events)
              (coro (each e events (yield (sse-event e))))
              (map sse-event events))
            (merge @{"content-type" "text/event-stream"
                     "cache-control" "no-cache"}
                   (or headers @{}))))
