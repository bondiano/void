### hub/intake — the receiving end: one route, and what a delivery is.
###
### A webhook arrives as bytes with a signature over exactly those
### bytes, so **the raw body is the thing** — everything else here is
### derived from it and could be recomputed. That decides the shape:
###
###   1. verify the signature over the bytes as they arrived,
###   2. put the bytes in `void/storage` under a key that is the
###      delivery's own id,
###   3. write a row that says where they are and what they were about,
###   4. answer 202 — accepted, not "delivered", because where this
###      event goes is a decision that happens after the connection is
###      closed.
###
### The bytes go to a store rather than into a column because they are
### the one thing worth keeping verbatim and the one thing nobody wants
### in a row: hundreds of kilobytes of somebody else's JSON, read once
### a month when a delivery is being argued about (ADR-0039). The row
### keeps what a person filters by.
###
### Idempotency is `X-GitHub-Delivery`: GitHub retries, and a retry is
### the same delivery rather than a second one. The column is unique,
### and a duplicate is a 202 with `duplicate` in it — never an error,
### because the sender did nothing wrong.
###
### The secret lives in `[:hub :sources <name> :signing-secret]` as a
### secret reference rather than a string (see `signing-secret` below),
### and a source this application does not know is a 404 before any
### hashing happens at all.
(import void/core/plugin :as plugin)
(import void/core/config :as config)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/db :as db)
(import void/storage)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import spork/json)
(import ./route)

(def log-ns "hub.intake")

# -- configuration -------------------------------------------------------

(def Config
  ``Schema of the `[:hub]` slice — **this application's whole slice**,
  declared by this plugin because this is the plugin that cannot start
  without it. A config key has one owner and its schema validates the
  whole slice, so ./route.janet's rules and ./telegram.janet's bot are
  named here and read there, each in its own hook.

  `void config explain :hub :sources` prints which layer put a value
  there, and no layer prints a secret: those are references resolved
  into boxes (see `signing-secret`).``
  {:sources [:optional :dictionary]
   # where a received delivery goes — ./route.janet
   :rules [:optional [:vector :dictionary]]
   # the bot this application speaks as — ./telegram.janet
   :telegram [:optional :dictionary]
   # who may read what was received — ./admin.janet
   :operators [:optional [:vector :string]]})

(def defaults
  "No sources and no rules: an application that has not been told about
  a source answers 404 on every intake path — the right thing to do
  with an endpoint nobody configured — and one with no rules receives
  and keeps deliveries without sending anything anywhere."
  {:sources {} :rules [] :operators []})

(var- settings defaults)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :hub/configure
   :doc "Resolve the [:hub] slice — the sources this hub receives from"
   :fn (fn configure [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :hub]) {})))
         (log/info "intake ready" :ns log-ns
                   # the names, never the secrets
                   :sources (sorted (keys (get settings :sources {})))))})

(defn source
  "The configuration of a named source, or nil when there is none."
  [name]
  (get (get settings :sources {}) (keyword name)))

(defn signing-secret
  ``What a source signs with. The configured value is a **secret
  reference** — `{:secret "GITHUB_WEBHOOK_SECRET"}` — which
  void/core/config resolved into an opaque box at load, so it is not in
  any printed config and not in any log line; `config/reveal` is the
  only way out of the box (void/mail does the same with an SMTP
  password). A plain string is accepted too, because a test that wants
  one should not have to invent an environment.

  Note the shape: the field is `:signing-secret` rather than `:secret`,
  because a map whose only key is `:secret` *is* a secret reference —
  `{:secret {:secret "ENV"}}` would be the alternative, and it reads
  like a typo.``
  [cfg]
  (def s (get cfg :signing-secret))
  (cond
    (config/secret? s) (config/reveal s)
    (string? s) s
    ""))

# -- the row -------------------------------------------------------------

# One received webhook. `delivery-id` is the sender's own id for it —
# unique, because a retry is the same delivery — and `body-key` says
# where the bytes went rather than holding them.
(db/defentity Delivery
  {:id [:int {:db/pk true :db/type "integer"}]
   :source [:string {:db/type "text"}]
   :event [:string {:db/type "text"}]
   :delivery-id [:string {:db/unique true :db/type "text"}]
   # what the payload was about, for the eye and for a filter. Both are
   # optional because both are the sender's business: a delivery whose
   # JSON this application cannot read is still a delivery it received
   :repo [:optional [:string {:db/type "text"}]]
   :sender [:optional [:string {:db/type "text"}]]
   :body-key [:string {:db/type "text"}]
   :size [:int {:db/type "integer"}]
   :received-at [:string {:db/type "text"}]}
  :db/table "deliveries")

(defn- now []
  (def d (os/date (os/time) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn find-by-delivery-id
  "The row a sender's delivery id points at, or nil."
  [delivery-id]
  (when delivery-id (db/one Delivery {:where [:= :delivery-id delivery-id]})))

# -- the signature -------------------------------------------------------

(defn signature-of
  ``What `X-Hub-Signature-256` should say for these bytes: GitHub's
  scheme is `sha256=<hex hmac-sha256 of the raw body>`. The same shape
  void/notify's webhook channel *sends* (ADR-0040), read from the other
  end.``
  [secret body]
  (string "sha256=" (crypto/hex (crypto/hmac-sha256 (string secret) (string body)))))

(defn signature-ok?
  ``Constant-time comparison, and `crypto/equal?` rather than `=`
  (ADR-0022): a signature check that returns early on the first wrong
  byte tells the sender how much of the guess was right.``
  [secret body given]
  (and (string? given)
       (crypto/equal? (signature-of secret body) given)))

# -- where the bytes go --------------------------------------------------

(defn- safe-id
  ``The sender's delivery id as a storage key may hold it, or nil. It
  is **checked, not laundered**: GitHub sends a UUID, and a string that
  is not one is somebody else's idea of an identifier — a key is not
  the place to find out what it can do (ADR-0039: the key is data, so
  the data is checked). Refusing is a 400 the sender can read; quietly
  rewriting it would put two deliveries under one key.``
  [id]
  (def cleaned (string/ascii-lower (string/replace-all "-" "" (or id ""))))
  (when (and (not (empty? cleaned))
             (<= (length cleaned) 64)
             (peg/match ~(* (some (range "az" "09")) -1) cleaned))
    cleaned))

(defn body-key
  ``Where a delivery's bytes live: `<source>/<yyyy>/<mm>/<id>.json`.
  Dated, because the first thing anybody asks of a store this size is
  "what can be deleted", and the id, because that is what a person has
  in their hand when they come looking.``
  [source-name id]
  (def d (os/date (os/time) true))
  (string/format "%s/%04d/%02d/%s.json"
                 (string source-name) (d :year) (inc (d :month)) id))

# -- what the payload says about itself ----------------------------------

(defn payload-of
  ``Somebody else's JSON, decoded **once** — the row wants two fields
  out of it and the message wants a few more, and parsing it twice
  would be paying twice for a value the bytes already are. nil when it
  cannot be read: a body this application does not understand is still
  a delivery it received.``
  [body]
  (def [ok payload] (protect (json/decode (string body) true)))
  (when (and ok (dictionary? payload)) payload))

(defn describe
  "The two things worth a column. Both are the sender's business, so
  both may be missing."
  [payload]
  (if (dictionary? payload)
    {:repo (get-in payload [:repository :full_name])
     :sender (get-in payload [:sender :login])}
    {}))

# -- the handler ---------------------------------------------------------

(defn- accepted [status body]
  (ring/content-type (ring/response status (string (json/encode body)))
                     "application/json"))

(defn receive
  ``POST /in/:source — the whole receiving end.

  The order is the point. Nothing is stored before the signature is
  checked, because storing first would make an unauthenticated stranger
  the author of this application's disk usage; and nothing is routed
  before the answer goes out, because the sender is owed 202 and not a
  tour of everything that happens next.``
  [req]
  (def name (get-in req [:params :source]))
  (def cfg (source name))
  (def body (or (req :body) ""))
  (cond
    (nil? cfg)
    (do (log/warn "delivery for an unknown source" :ns log-ns :source name)
        (accepted 404 {:error "unknown source"}))

    (not (signature-ok? (signing-secret cfg)
                        body
                        (get-in req [:headers "x-hub-signature-256"])))
    (do (log/warn "delivery with a signature that does not check out"
                  :ns log-ns :source name)
        (accepted 401 {:error "signature"}))

    (do
      (def delivery-id (get-in req [:headers "x-github-delivery"]))
      (def id (safe-id delivery-id))
      (def event (or (get-in req [:headers "x-github-event"]) "unknown"))
      (cond
        (nil? id)
        (accepted 400 {:error "no delivery id"})

        # a retry is the same delivery: the bytes are already kept and
        # the row already exists, and saying so is the honest 202
        (find-by-delivery-id delivery-id)
        (accepted 202 {:status "duplicate" :delivery delivery-id})

        (do
          (def key (body-key name id))
          (storage/put! key body {:content-type "application/json"})
          (def payload (payload-of body))
          (def row (db/insert! Delivery
                               (merge {:source (string name)
                                       :event event
                                       :delivery-id delivery-id
                                       :body-key key
                                       :size (length body)
                                       :received-at (now)}
                                      (describe payload))))
          (log/info "delivery received" :ns log-ns
                    :source name :event event :delivery delivery-id
                    :size (length body) :key key)
          # Where it goes is ./route.janet's decision, and it is made
          # **here**, on this fiber, because that is where the request
          # is: projecting a notification is what happens now, and
          # delivering it is what void/notify-jobs does later
          # (ADR-0040). A routing failure is logged and does not undo a
          # delivery that was received and kept — the sender is owed
          # its 202 either way
          (def [ok err] (protect (route/dispatch! row payload)))
          (unless ok
            (log/error "routing a received delivery failed" :ns log-ns
                       :delivery delivery-id :err err))
          (accepted 202 {:status "received" :id (row :id)}))))))

# -- replay --------------------------------------------------------------
#
# A delivery is kept in two halves — a row and the bytes it points at —
# and replay is what those two halves are *for*. `void hub replay`
# (./ops.janet) is the operator's end of it; both functions are here
# because this is the module that knows where a delivery lives.
#
# **Replay is the second half of receiving, deliberately.** It routes
# again; it does not receive again. Receiving is a signature over bytes
# that have already been verified, and re-running it would either be
# refused as a duplicate (the delivery id is unique — that is the whole
# point) or write a second row for one delivery. So what is replayed is
# the decision, which is the half that has bugs in it: a rule that did
# not match, a message that came out wrong, a chat that was not
# configured yet.
#
# That is also what takes the tunnel out of development. One real
# delivery has to reach this application once — through a tunnel, or
# from another deployment's store — and after that the interesting
# half runs as many times as it takes, with no GitHub, no public
# hostname and no waiting for somebody to push.

(defn find-delivery
  ``The delivery an operator named: the sender's own id (what GitHub
  shows on its deliveries page, and what a support request quotes), or
  this application's row id. Both, because an operator has whichever
  one they happen to be looking at.``
  [ident]
  (def s (string ident))
  (or (find-by-delivery-id s)
      (when-let [n (scan-number s)]
        (when (int? n) (db/find Delivery n)))))

(defn stored-body
  "The bytes of a kept delivery, or nil when the store no longer holds
  them (a sweep, a bucket the deployment moved off)."
  [row]
  (storage/fetch (row :body-key)))

(defn replay!
  ``Route a kept delivery again, from the bytes as they arrived.
  Returns what `route/dispatch!` returned — one result per matching
  rule, so a caller can print what it queued and see that a delivery
  nobody routes is a delivery nobody routes.``
  [row]
  (def body
    (or (stored-body row)
        (errorf "the store no longer holds %s (key %s)"
                (row :delivery-id) (row :body-key))))
  (log/info "replaying a kept delivery" :ns log-ns
            :delivery (row :delivery-id) :event (row :event)
            :size (length body))
  (route/dispatch! row (payload-of body)))

# -- routes --------------------------------------------------------------

(router/defroutes :hub/intake-routes
  # No CSRF token and no session: the caller is a machine with a
  # signature, and this route is the one place in the application where
  # that is the whole of the authentication
  (POST "/in/:source" receive {:name :intake/receive}))

(plugin/defplugin hub/intake
  :doc "Receive signed webhook deliveries: verify over the raw bytes, keep the bytes in storage, keep what a person filters by in a row, answer 202."
  :version "0.1.0"
  :requires {:void/http ">=0.0.1" :void/db ">=0.0.1"
             :void/crypto ">=0.0.1" :void/storage ">=0.0.1"}
  :config-key :hub
  :config-schema Config
  :config-defaults defaults)
