### void/redis/config — from the [:redis] config slice to the options
### one connection opens with (SPEC.md §5.10).
###
### Two spellings meet here. A URL is what a deployment hands you —
### REDIS_URL is as much a convention as DATABASE_URL — and explicit
### keys are what a config file is pleasant to write. They compose the
### way [:db-postgres] does: the URL is taken apart into the same
### keywords the explicit keys set, and an explicit key wins, so
###
###     {:url "redis://cache.internal:6379/0" :database 3}
###
### connects to database 3 and needs no comment explaining which half
### won. Percent-escapes in the userinfo are decoded, because a
### password containing @ or / has no other way through a URL.
###
### TLS is not this package's (ADR-0010): `rediss://` parses into
### `{:tls true}`, and whether the connection can honour that is
### decided where the socket opens — `void/redis/conn` holds the seam
### `void/tls` closes (ADR-0038). A composition without the plugin
### refuses a `rediss://` URL at connect time with both ways out
### named; it never quietly speaks plaintext to a URL that asked for
### encryption.
###
### Nothing here opens a socket: this module is pure parsing, which is
### why all of it is testable with no redis anywhere.

(def Config
  ``Schema of the [:redis] config slice.``
  {:url [:optional :string]
   :host [:optional :string]
   :port [:optional [:int {:min 1 :max 65535}]]
   :unix [:optional :string]
   :username [:optional :string]
   :password [:optional :string]
   :database [:optional [:int {:min 0}]]

   # encrypt the connection (what a rediss:// URL sets) — honoured by
   # the void/tls seam in ./conn, refused loudly without it (ADR-0038)
   :tls [:optional :boolean]

   # protocol version asked for in HELLO; 2 pins RESP2 for a server
   # (or a proxy) that answers HELLO with an error
   :protocol [:optional [:enum 2 3]]
   :client-name [:optional :string]

   :connect-timeout [:optional [:number {:min 0}]]
   :timeout [:optional [:number {:min 0}]]

   # the largest blob one reply may carry: a 14-byte header can claim
   # gigabytes, and without a cap the client allocates them before a
   # single payload byte arrives. Raise it where values that large are
   # real; the connection that exceeds it is broken, not resynced
   :max-bulk [:optional [:int {:min 1}]]

   # every key this client builds is prefixed with this, which is what
   # makes one redis serve several applications (and one developer's
   # laptop serve several checkouts) without them colliding
   :prefix [:optional :string]
   :codec [:optional :keyword]
   :retry [:optional :boolean]

   :pool [:optional {:size [:optional [:int {:min 1}]]
                     :checkout-timeout [:optional [:number {:min 0}]]}]

   :pubsub [:optional {:enabled [:optional :boolean]
                       :backoff [:optional {:min [:optional [:number {:min 0}]]
                                            :max [:optional [:number {:min 0}]]
                                            :factor [:optional [:number {:min 1}]]}]}]

   :session [:optional {:prefix [:optional :string]}]})

(def defaults
  ``Defaults of the [:redis] slice: a local server on the standard
  port, RESP3 (redis 6+; a RESP2 server is detected at the handshake,
  not configured for), and a pool of eight — a redis command is
  sub-millisecond, so a pool exists to let fibers overlap round trips
  rather than to hold work.``
  {:host "127.0.0.1"
   :port 6379
   :database 0
   :protocol 3
   :connect-timeout 5
   :timeout 5
   # 64 MB: far above any value a cache or a session writes, far below
   # what a lying length header could make the reader allocate
   :max-bulk (* 64 1024 1024)
   :prefix ""
   :codec :raw
   :retry true
   :pool {:size 8 :checkout-timeout 5}
   :pubsub {:enabled true}
   :session {:prefix "session:"}})

# -- URLs ----------------------------------------------------------------

(def- url-peg
  (peg/compile
    ~{:main (* (group (* '(some (if-not ":" 1)) "://"))
               (group (? :userinfo))
               (group :hostport)
               (group (? (* "/" '(any (if-not "?" 1)))))
               (group (? (* "?" '(any 1))))
               -1)
      :userinfo (* '(any (if-not (set ":@/?") 1))
                   (? (* ":" '(any (if-not (set "@/?") 1))))
                   "@")
      # a bracketed IPv6 literal, or everything up to the port/path
      :hostport (* (+ (* "[" '(any (if-not "]" 1)) "]")
                      '(any (if-not (set ":/?") 1)))
                   (? (* ":" (/ '(some (range "09")) ,scan-number))))}))

(defn percent-decode
  "A URL component with its %XX escapes resolved."
  [s]
  (if (string/find "%" s)
    (first (peg/match ~(% (any (+ (/ (* "%" (<- (repeat 2 (range "09" "af" "AF"))))
                                      ,(fn [h] (string/from-bytes (scan-number (string "0x" h)))))
                                   '1)))
                       s))
    s))

(defn parse-url
  ``A redis URL as the keywords the slice speaks:

      redis://user:pass@host:6379/2   -> {:host :port :username :password :database}
      redis://host                    -> {:host "host"}
      unix:///run/redis.sock?db=1     -> {:unix "/run/redis.sock" :database 1}

  Query parameters are accepted for the settings a URL customarily
  carries (`db`, `timeout`, `client_name`); an unknown one is an error
  rather than a silently dropped instruction.``
  [url]
  (def m (or (peg/match url-peg url)
             (errorf "not a redis url: %q" url)))
  (def [scheme-g user-g host-g path-g query-g] m)
  (def scheme (string/ascii-lower (in scheme-g 0)))
  (def out @{})

  (case scheme
    "redis" nil
    "unix" nil
    "rediss" (put out :tls true)
    (errorf "unknown redis url scheme %q (expected redis://, rediss:// or unix://)" scheme))

  (when (>= (length user-g) 1)
    (def user (percent-decode (in user-g 0)))
    (unless (empty? user) (put out :username user))
    (when (>= (length user-g) 2)
      (put out :password (percent-decode (in user-g 1)))))

  (def path (when (>= (length path-g) 1) (percent-decode (in path-g 0))))

  (if (= "unix" scheme)
    # the grammar ate the slash that separates authority from path,
    # and for a socket that slash is the first character of the name
    (put out :unix (if (and path (not (empty? path)))
                     (string "/" path)
                     (errorf "unix url %q has no socket path" url)))
    (do
      (def host (in host-g 0))
      (unless (empty? host) (put out :host host))
      (when (>= (length host-g) 2) (put out :port (in host-g 1)))
      (when (and path (not (empty? path)))
        (def db (scan-number path))
        (unless (and (number? db) (= db (math/trunc db)) (>= db 0))
          (errorf "redis url %q: %q is not a database number" url path))
        (put out :database db))))

  (when (>= (length query-g) 1)
    (each pair (string/split "&" (in query-g 0))
      (unless (empty? pair)
        (def i (string/find "=" pair))
        (def k (string/ascii-lower (percent-decode (if i (string/slice pair 0 i) pair))))
        (def v (percent-decode (if i (string/slice pair (inc i)) "")))
        (case k
          "db" (put out :database (scan-number v))
          "database" (put out :database (scan-number v))
          "client_name" (put out :client-name v)
          "timeout" (put out :timeout (scan-number v))
          "connect_timeout" (put out :connect-timeout (scan-number v))
          "protocol" (put out :protocol (scan-number v))
          (errorf "redis url %q: unknown parameter %q" url k)))))
  out)

# -- the slice as connection options -------------------------------------

(def- connection-keys
  "The slice keys one connection is opened with."
  [:host :port :unix :username :password :database :tls :protocol
   :client-name :connect-timeout :timeout :max-bulk])

(defn options
  ``The [:redis] slice as the option table ./conn opens with: the URL
  taken apart first, explicit keys on top, and the connection keys
  alone (the pool, the prefix and the codec belong to layers above a
  socket).``
  [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (def from-url (if-let [u (get cfg :url)] (parse-url u) @{}))
  (def out @{})
  (each k connection-keys
    (def v (if (nil? (get cfg0 k)) (get from-url k) (get cfg0 k)))
    (def v (if (nil? v) (get cfg k) v))
    (unless (nil? v) (put out k v)))
  # a unix socket and a host are alternatives, and libpq's habit of
  # letting a default quietly win is not one to copy: a slice that
  # names a socket connects to it, and the defaulted host is dropped
  # rather than left to confuse the health output
  (when (get out :unix)
    (put out :host nil)
    (put out :port nil))
  out)

(defn describe
  ``What this configuration connects to, for logs and health — a
  password never appears, in either spelling.``
  [cfg0]
  (def o (options cfg0))
  (def cfg (merge defaults (or cfg0 {})))
  {:server (if-let [sock (o :unix)]
             (string "unix:" sock)
             (string (o :host) ":" (o :port)))
   :database (get o :database 0)
   :protocol (get o :protocol 3)
   :prefix (get cfg :prefix "")
   :codec (get cfg :codec :raw)})

(defn pool-options
  "The [:redis :pool] slice, defaults filled in."
  [cfg0]
  (merge (get defaults :pool) (get (or cfg0 {}) :pool {})))
