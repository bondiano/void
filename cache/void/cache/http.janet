### void/cache-http — response caching on routes that ask for it
### (SPEC.md part II §2.5 row `:void.cache/response`).
###
### The piece of void/cache that needs void/http, kept a separate
### plugin so a CLI or a worker never drags the HTTP kernel in — what
### void/db-http is to void/db. A route (or a whole group) marked
###
###     {:void.cache/response {:ttl 60}}
###     {:void.cache/response {:ttl 60 :vary ["accept-language"]}}
###
### answers from the cache when it can. The wrapper sits between
### parsing and the session, which is the slot that makes the two
### promises worth having: a hit is served before any session is
### opened (so a hit can never carry a Set-Cookie), and it is served
### after the request has been parsed (so the key is built from a path
### and a query, not from a byte string).
###
### **This is a shared cache, and it behaves like one.** One entry is
### served to everybody who asks for that key, so a route whose answer
### depends on who is asking either says so with `:vary` or is not
### marked at all. Four refusals enforce the rest, and each one logs
### the route it refused rather than failing quietly:
###
###   - a request carrying `authorization` bypasses the cache entirely,
###     read and write (RFC 9111 §3.5 says a shared cache must not
###     store those; serving one is the same mistake in reverse)
###   - a response carrying `set-cookie` is never stored — that cookie
###     belongs to one visitor, and the cache would hand it to the next
###   - a response saying `cache-control: private` or `no-store` is
###     never stored: the handler said so
###   - a streaming body (a fiber, an iterable, SSE) is never stored,
###     because it can be consumed once and a cache exists to replay
###
### Only 200s are stored. A 404 that is expensive to compute is a real
### thing, but it is also the answer most likely to change the moment
### somebody creates the row, and a route that wants it cached can say
### so with `remember` in the handler, where the invalidation is
### visible.
###
### `:ttl 0` is how a route opts out of a TTL its group set: the merge
### strategy for this key is `:replace`, so the route's map wins whole.
###
### **What it costs a route that is not marked: nothing.** The
### contribution carries a `:when`, and void/http evaluates it once at
### table-build time — a route without the key has no cache wrapper in
### its chain at all, so there is no B1 line to report here. The test
### suite pins that (`http-test.janet`), because "it is free" is a
### claim that stops being true silently.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/middleware :as middleware)
(import void/http/ring :as ring)
(import ./key :as key)
(import ./state :as state)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.cache.http")

(def Config
  "Schema of the [:cache-http] config slice."
  {:prefix [:optional :string]
   :ttl [:optional [:number {:min 0}]]
   # the name of the hit/miss header, or false for a cache that says
   # nothing about itself
   :header [:optional [:or :string :boolean]]})

(def defaults
  "Defaults of the [:cache-http] slice."
  {:prefix "response:"
   :header "x-cache"})

(var settings
  "The [:cache-http] slice, read at :before-start — the middleware runs
  on the hot path and has no business reaching into the boot value
  there."
  defaults)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :cache-http/capture-config
   :doc "Read the [:cache-http] slice once, before the route table is built"
   :fn (fn capture [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :cache-http]) {}))))})

# -- the metadata key ----------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.cache/response
   :schema {:ttl [:optional [:number {:min 0}]]
            :vary [:optional [:vector [:or :string :keyword]]]}
   :doc "Cache this route's 200 responses in the shared cache for :ttl seconds (0 opts out of a group's setting), keyed by method, path, query and the request headers named in :vary"
   :merge :replace})

# -- keys ----------------------------------------------------------------

(defn- vary-values [req names]
  (seq [n :in names] (ring/request-header req (string/ascii-lower (string n)))))

(defn response-key
  ``The key one request is cached under: method, path, the query
  rendered canonically (so `?b=2&a=1` and `?a=1&b=2` are one entry),
  and the values of the headers the route varies on.``
  [req spec]
  (def names (get spec :vary []))
  (string (settings :prefix)
          (string/ascii-upper (string (get req :method :get)))
          " " (get req :path "/")
          " " (key/canonical (get req :query {}))
          (if (empty? names) "" (string " " (key/canonical (vary-values req names))))))

# -- what may be cached --------------------------------------------------

(def- warned @{})

(defn- warn-once
  ``Say once per route why its responses are not being cached. Once,
  because a misconfiguration that logs per request is a second
  incident on top of the first.``
  [req reason]
  (def route (or (get-in req [:void/route :name]) (get req :path "?")))
  (def seen [route reason])
  (unless (get warned seen)
    (put warned seen true)
    (log/warn "not caching this route's responses" :ns log-ns
              :route route :reason reason)))

(defn- private-response? [resp]
  (when-let [cc (get-in resp [:headers "cache-control"])]
    (def s (string/ascii-lower (if (indexed? cc) (string/join (map string cc) ",") (string cc))))
    (or (string/find "no-store" s) (string/find "private" s))))

(defn- cacheable-request? [req spec]
  (def method (get req :method :get))
  (cond
    (not (or (= :get method) (= :head method))) false
    # a shared cache must not store a response to a request with
    # Authorization (RFC 9111 §3.5), and must not answer one from an
    # entry somebody else's request put there — unless the route
    # varies on it and knows what it is doing
    (and (ring/request-header req "authorization")
         (not (index-of "authorization"
                        (map |(string/ascii-lower (string $)) (get spec :vary [])))))
    false
    true))

(defn- storable-response? [req resp]
  (cond
    (not (dictionary? resp)) false
    (not= 200 (get resp :status)) false
    (not (bytes? (get resp :body)))
    (do (warn-once req :streaming-body) false)
    (get-in resp [:headers "set-cookie"])
    (do (warn-once req :set-cookie) false)
    (private-response? resp)
    (do (warn-once req :cache-control) false)
    true))

# -- the middleware ------------------------------------------------------

(defn- mark [resp value]
  (def h (settings :header))
  (when (and (string? h) (dictionary? resp) (table? (get resp :headers)))
    (put (resp :headers) h value))
  resp)

(defn- stored-response [entry]
  (def resp @{:status (entry :status)
              :headers (merge-into @{} (get entry :headers {}))
              :body (entry :body)})
  (def age (max 0 (- (os/time) (get entry :stored-at (os/time)))))
  (ring/header resp "age" (string age))
  (mark resp "HIT"))

(defn respond
  ``Serve one request through the cache: a hit is replayed, a miss
  reaches `handler` and its response is stored when it may be (see the
  module docstring). `spec` is the route's `:void.cache/response`
  value.``
  [handler spec req]
  (if (not (cacheable-request? req spec))
    (mark (handler req) "BYPASS")
    (let [k (response-key req spec)
          [found entry] (state/fetch k)]
      (if found
        (stored-response entry)
        (let [resp (handler req)]
          (when (storable-response? req resp)
            (state/put! k
                        {:status (resp :status)
                         :headers (freeze (get resp :headers {}))
                         :body (string (resp :body))
                         :stored-at (os/time)}
                        (get spec :ttl (settings :ttl))))
          (mark resp "MISS"))))))

(plugin/contribute! :void.http/middleware
  {:name :void.cache/response
   # after parsing, before the session: a hit is answered without ever
   # opening one, which is also why a hit can carry no Set-Cookie
   :phase 2500
   :doc "Serve routes marked :void.cache/response from the shared cache, and store their 200 responses"
   :when (fn [rmeta] (dictionary? (get rmeta :void.cache/response)))
   :wrap (fn [handler]
           # :wrap sees the handler and not the route, so the spec is
           # read off the request's route entry — one lookup into a
           # table that was merged and precompiled at build time, and
           # nothing else on this path is computed per request
           (fn cache-response [req]
             (respond handler
                      (get-in req [:void/route :meta :void.cache/response] {})
                      req)))})

(plugin/defplugin void/cache-http
  :doc "Response caching for void/http: routes marked :void.cache/response answer from the shared cache, with the refusals a shared cache needs (never a Set-Cookie, never an Authorization request, never a stream)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/cache ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :cache-http
  :config-schema Config
  :config-defaults defaults)
