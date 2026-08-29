### void/ws — WebSocket (RFC 6455) over the HTTP kernel (SPEC §5.6,
### ADR-0028, ROADMAP 4.2).
###
### **A websocket is a route.** `ws/accept` is called from an ordinary
### handler, so the handshake has already been routed, has already had
### its session loaded, has already met `void/auth`, `void/authz` and
### `void/security`, and carries the route metadata every other request
### carries. Nothing in this package re-implements any of that, and no
### plugin needed a second code path for sockets:
###
###     (defn live [req]
###       (ws/accept req {:rooms [:lobby]
###                       :on-message (fn [conn msg]
###                                     (ws/broadcast! :lobby (msg :data)))}))
###
###     (defroutes :chat/routes
###       (GET "/live" live {:void.ws/socket true
###                          :void.authz/policy :chat/may-listen}))
###
### The `:void.ws/socket` mark is required rather than decorative: it
### is what tells the kernel that a handler deadline must not be
### applied to this route (a `:void.http/timeout` would cancel the
### connection mid-conversation), and the boot fails if a socket route
### carries one.
###
### **What lives where.** ./frame is RFC 6455 §5 as pure functions,
### ./handshake is §4, ./conn is one connection (two fibers, a bounded
### outbound queue and the close handshake), ./rooms is the registry
### and the fan-out, ./client is the other end — the same framing read
### backwards, which is what the suite and the B4 load generator talk
### to the server with. `void/ws-htmx` (./htmx) is a separate plugin in
### this package: an application whose sockets carry JSON never drags a
### template engine in.
###
### **What it does not do.** No `permessage-deflate` (an extension is a
### negotiation, a compressor and a second set of framing rules, and
### void has no compressor); no cross-worker fan-out (see ./rooms — it
### is three lines of `void/bus` and they are the application's);
### no TLS (ADR-0010, the same relay next to the process that serves
### `https://`, which is where `wss://` terminates too).

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/http/ring :as ring)
(import ./frame :as frame)
(import ./handshake :as handshake)
(import ./conn :as conn)
(import ./rooms :as rooms)

(def log-ns "void.ws")

# -- the running registry ------------------------------------------------

(var current-registry
  "The registry of the running :ws/registry component — one per
  process, like plugin/current-boot. With prefork workers each has its
  own, and that boundary is ADR-0010's (see ./rooms)."
  nil)

(defn registry
  "The running registry, or a readable error."
  []
  (or current-registry
      (error "void/ws is not started — add :void/ws to :plugins (the :ws/registry component holds the connections)")))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:ws] config slice."
  {:max-frame [:optional [:int {:min 125}]]
   :max-message [:optional [:int {:min 125}]]
   :send-queue [:optional [:int {:min 1}]]
   :overflow [:optional [:enum :close :drop]]
   :close-timeout [:optional [:number {:min 0}]]
   :ping-interval [:optional [:number {:min 0}]]
   :pong-timeout [:optional [:number {:min 0}]]
   :sweep-interval [:optional [:number {:min 0}]]
   :max-connections [:optional [:int {:min 1}]]})

(def defaults
  ``Defaults of the [:ws] slice — the per-connection limits of ./conn
  and the registry settings of ./rooms in one place, because an
  operator tuning a socket layer tunes both.``
  (merge conn/defaults rooms/defaults))

(var settings
  "The [:ws] slice, read at :before-start: a handshake happens on the
  hot path and has no business reaching into the boot value there."
  defaults)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :ws/capture-config
   :doc "Read the [:ws] slice once, before the route table is built"
   :fn (fn capture [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :ws]) {}))))})

# -- the route mark ------------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.ws/socket
   :schema :boolean
   :doc "This route answers a WebSocket handshake: no handler deadline may apply to it, and `void routes` says so"
   :merge :replace})

(plugin/contribute! :void.core/hooks
  {:hook :void.http/route-added
   :phase 500
   :name :ws/no-deadline-on-sockets
   :doc "A socket route may not carry :void.http/timeout — a deadline would cancel the conversation, not a request"
   :fn (fn check-route [_ entry]
         (when (and (get-in entry [:meta :void.ws/socket])
                    (get-in entry [:meta :void.http/timeout]))
           (errorf (string "route %q is marked :void.ws/socket and carries "
                           ":void.http/timeout %q — a websocket lives longer than any "
                           "request deadline, and the deadline would cancel the "
                           "connection mid-conversation. Drop the timeout on this route "
                           "(idle peers are handled by [:ws :ping-interval] instead).")
                   (entry :name)
                   (get-in entry [:meta :void.http/timeout]))))})

# -- accepting a handshake -----------------------------------------------

(def- spec-keys
  {:on-open true :on-message true :on-close true :protocols true
   :rooms true :max-frame true :max-message true :send-queue true
   :overflow true :close-timeout true})

(defn accept
  ``Answer a websocket handshake from inside an ordinary route
  handler. Returns the response to return: the 101 that hands the
  socket over, or the refusal the handshake earned (405/400/426, or
  503 when the process is already at `[:ws :max-connections]`).

  The spec:
    :on-open     (fn [conn])                    after the upgrade
    :on-message  (fn [conn {:type :data}])      one complete message
    :on-close    (fn [conn {:code :name :reason}])
    :protocols   subprotocols this route speaks, best first
    :rooms       rooms to join on open
    plus per-connection overrides of the [:ws] limits (:max-frame,
    :max-message, :send-queue, :overflow, :close-timeout)

  Handlers run in the connection's own fiber, one message at a time —
  a slow `:on-message` delays that peer and nobody else. An error
  thrown by one closes the connection with 1011 and is logged; it does
  not take the process, the fiber or any other connection with it.``
  [req spec]
  (default spec {})
  (eachk k spec
    (unless (in spec-keys k)
      (errorf "ws/accept: unknown key %q (known: %s)"
              k (string/join (map |(string/format "%q" $) (sorted (keys spec-keys))) " "))))
  (unless (get-in req [:void/route :meta :void.ws/socket])
    (errorf (string "route %q answers a websocket handshake but is not marked "
                    ":void.ws/socket true — the mark is what keeps a handler "
                    "deadline off a route that holds a connection open")
            (get-in req [:void/route :name] (req :path))))
  (def reg (registry))
  (if (rooms/full? reg)
    (do
      (log/warn "refusing a websocket — at the connection limit" :ns log-ns
                :limit (get-in reg [:config :max-connections]))
      (ring/response 503 "503 Service Unavailable — too many websocket connections"
                     @{"content-type" "text/plain; charset=utf-8"
                       "retry-after" "10"}))
    (let [checked (handshake/check req (get spec :protocols))]
      (if (get checked :status)
        checked                                  # a refusal, as HTTP
        (ring/upgrade
          (handshake/response-headers (checked :key) (checked :protocol))
          (fn take-over [socket leftover]
            (def c (conn/make socket
                              (merge (tabseq [k :in [:max-frame :max-message
                                                     :send-queue :overflow
                                                     :close-timeout]]
                                       k (get spec k (settings k)))
                                     {:request req
                                      :protocol (checked :protocol)
                                      :registry reg})))
            (rooms/register! reg c)
            (each name (get spec :rooms []) (rooms/join! reg c name))
            (conn/serve c
                        {:on-open (get spec :on-open)
                         :on-message (get spec :on-message)
                         :on-close (get spec :on-close)
                         :on-detach (fn detach [cc] (rooms/unregister! reg cc))}
                        leftover)))))))

(defn handler
  ``A route handler from a spec — `accept` with the spec already
  bound, for the common case where the socket is the whole route:

      (def live (ws/handler {:rooms [:lobby] :on-message echo}))
      (GET "/live" live {:void.ws/socket true})``
  [spec]
  (fn ws-route [req] (accept req spec)))

# -- what a handler says to one peer -------------------------------------

(def send! "See conn/send! — one text message." conn/send!)
(def send-binary! "See conn/send-binary!." conn/send-binary!)
(def close! "See conn/close! — begin the closing handshake." conn/close!)
(def ping! "See conn/ping!." conn/ping!)
(def open? "See conn/open?." conn/open?)
(def info "See conn/info — a snapshot of one connection." conn/info)
(def stats "See conn/stats — what this process's sockets have done." conn/stats)

(defn send-json!
  "Encode a value as JSON and send it as one text message."
  [c value]
  (conn/send! c (json/encode value)))

(defn json-body
  ``The JSON value in a message, or nil when it is not JSON. A socket
  that carries JSON carries text somebody else wrote, so a payload
  that does not parse is a message to ignore rather than an exception
  to raise in the connection fiber.``
  [message]
  (when (= :text (get message :type))
    (def [ok value] (protect (json/decode (message :data) true)))
    (when ok value)))

# -- what a handler says to a room ---------------------------------------

(defn join!
  "Put a connection in a room."
  [c name]
  (rooms/join! (registry) c name))

(defn leave!
  "Take a connection out of a room."
  [c name]
  (rooms/leave! (registry) c name))

(defn broadcast!
  ``Send a message to every connection in a room; returns how many
  took it. Options: :except <conn>, :binary. The message is framed
  once for the whole room (./rooms).``
  [name message &opt opts]
  (rooms/broadcast! (registry) name message opts))

(defn broadcast-json!
  "Broadcast a value as JSON."
  [name value &opt opts]
  (rooms/broadcast! (registry) name (json/encode value) opts))

(defn broadcast-all!
  "Broadcast to every connection of this process."
  [message &opt opts]
  (rooms/broadcast-all! (registry) message opts))

(defn members
  "The connections in a room."
  [name]
  (rooms/members (registry) name))

(defn room-names
  "Every room with a member in this process."
  []
  (rooms/room-names (registry)))

(defn connections
  "Every websocket connection this process holds."
  []
  (rooms/connections (registry)))

(defn status
  "What this process's socket layer looks like right now."
  []
  (rooms/status (registry)))

# -- the component -------------------------------------------------------

(def registry-component
  (system/component :ws/registry
    :doc "Every websocket connection this process holds, the rooms they
    are in, and the one fiber that pings the idle ones. Depends on
    :http/server so that a drain says goodbye on the sockets before the
    listener goes: stopping runs in reverse dependency order."
    :deps [:http/server]
    :config {:key :ws}
    :start
    (fn start [_ cfg]
      (def reg (rooms/make (merge defaults (or cfg {}))))
      (rooms/start-sweeper! reg)
      (set current-registry reg)
      reg)
    :stop
    (fn stop [reg]
      (rooms/stop-sweeper! reg)
      (rooms/close-all! reg :going-away "server is shutting down")
      # give the close frames a moment to reach the wire before the
      # HTTP server (which stops next) cuts the sockets underneath
      (ev/sleep 0.05)
      (set current-registry nil)
      reg)
    :health
    (fn health [reg]
      (def s (rooms/status reg))
      (merge {:status (if (>= (s :connections) (s :limit)) :degraded :up)} s))))

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/ws
  :doc "WebSocket (RFC 6455) over the void/http kernel: the handshake answered from an ordinary route handler, framing, ping/pong and the close handshake, a fiber per connection with a bounded outbound queue, plus rooms and broadcast."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :ws
  :config-schema Config
  :config-defaults defaults
  :components [registry-component])
