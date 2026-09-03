### intake/service — the receiving end, minus the request.
###
### A webhook arrives as bytes with a signature over exactly those
### bytes, so **the raw body is the thing** — everything else here is
### derived from it and could be recomputed. That decides the order,
### and the order is the design:
###
###   1. verify the signature over the bytes as they arrived,
###   2. put the bytes in `void/storage` under a key that is the
###      delivery's own id,
###   3. write a row that says where they are and what they were about,
###   4. answer 202 — accepted, not "delivered", because where this
###      event goes is a decision that happens after the connection is
###      closed.
###
### Steps 1–3 are here; step 4 is ./intake.controller.janet, which is
### the only file in this module that knows what a status code is.
###
### Idempotency is `X-GitHub-Delivery`: GitHub retries, and a retry is
### the same delivery rather than a second one. The column is unique
### (./intake.repository.janet), and a duplicate is a 202 with
### `duplicate` in it — never an error, because the sender did nothing
### wrong.
###
### The secret lives in `[:hub :sources <name> :signing-secret]` as a
### secret reference rather than a string (see `signing-secret`), and a
### source this application does not know is a 404 before any hashing
### happens at all.
(import void/core/config :as config)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/storage)
(import spork/json)
(import ../routing/routing.service :as routing)
(import ./intake.repository :as deliveries)

(def log-ns "hub.intake")

# -- the sources this hub receives from ----------------------------------

(var- sources {})

(defn configure!
  "Called from the application's :before-start hook (src/app.janet).
  Nothing is configured by default: an endpoint nobody set up answers
  404 rather than accepting anonymous bytes."
  [slice]
  (set sources (or (get slice :sources) {}))
  (log/info "intake ready" :ns log-ns
            # the names, never the secrets
            :sources (sorted (keys sources))))

(defn source
  "The configuration of a named source, or nil when there is none."
  [name]
  (get sources (keyword name)))

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

# -- the signature -------------------------------------------------------

(defn signature-of
  ``What `X-Hub-Signature-256` should say for these bytes: GitHub's
  scheme is `sha256=<hex hmac-sha256 of the raw body>`. The same shape
  void/notify's webhook channel *sends*, read from the other end.``
  [secret body]
  (string "sha256=" (crypto/hex (crypto/hmac-sha256 (string secret) (string body)))))

(defn signature-ok?
  ``Constant-time comparison, and `crypto/equal?` rather than `=`
: a signature check that returns early on the first wrong
  byte tells the sender how much of the guess was right.

  Takes the source's configuration rather than its secret, so the
  revealed value never leaves this file.``
  [cfg body given]
  (and (string? given)
       (crypto/equal? (signature-of (signing-secret cfg) body) given)))

# -- where the bytes go --------------------------------------------------

(defn- safe-id
  ``The sender's delivery id as a storage key may hold it, or nil. It is
  **checked, not laundered**: GitHub sends a UUID, and a string that is
  not one is somebody else's idea of an identifier — a key is not the
  place to find out what it can do (the key is data, so the data is
  checked). Refusing is a 400 the sender can read; quietly rewriting it
  would put two deliveries under one key.``
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
  out of it and the message wants a few more, and parsing it twice would
  be paying twice for a value the bytes already are. nil when it cannot
  be read: a body this application does not understand is still a
  delivery it received.``
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

# -- receiving -----------------------------------------------------------

(defn receive!
  ``Keep a delivery whose signature has already checked out, and route
  it. Takes values rather than a request — `{:source :event :delivery-id
  :body}` — and answers with one of

      {:status :no-id}
      {:status :duplicate :delivery-id ...}
      {:status :received :row ...}

  which is what the controller turns into 400 and 202.

  Where a delivery goes is ../routing's decision, and it is made
  **here**, on the fiber the request is on: projecting a notification is
  what happens now, and delivering it is what void/notify-jobs does
  later. A routing failure is logged and does not undo a delivery that was
  received and kept — the sender is owed its 202 either way.``
  [opts]
  (def name (opts :source))
  (def body (or (opts :body) ""))
  (def delivery-id (opts :delivery-id))
  (def id (safe-id delivery-id))
  (cond
    (nil? id) {:status :no-id}

    # a retry is the same delivery: the bytes are already kept and the
    # row already exists, and saying so is the honest 202
    (deliveries/by-delivery-id delivery-id)
    {:status :duplicate :delivery-id delivery-id}

    (do
      (def key (body-key name id))
      (storage/put! key body {:content-type "application/json"})
      (def payload (payload-of body))
      (def row (deliveries/create!
                 (merge {:source (string name)
                         :event (or (opts :event) "unknown")
                         :delivery-id delivery-id
                         :body-key key
                         :size (length body)}
                        (describe payload))))
      (log/info "delivery received" :ns log-ns
                :source name :event (row :event) :delivery delivery-id
                :size (length body) :key key)
      (def [ok err] (protect (routing/dispatch! row payload)))
      (unless ok
        (log/error "routing a received delivery failed" :ns log-ns
                   :delivery delivery-id :err err))
      {:status :received :row row})))

# -- replay --------------------------------------------------------------
#
# A delivery is kept in two halves — a row and the bytes it points at —
# and replay is what those two halves are *for*. `void hub replay`
# (../ops/ops.cli.janet) is the operator's end of it; the functions are
# here because this is the module that knows where a delivery lives.
#
# **Replay routes again; it does not receive again.** Receiving is a
# signature over bytes that have already been verified, and re-running
# it would either be refused as a duplicate (the delivery id is unique —
# that is the whole point) or write a second row for one delivery. So
# what is replayed is the decision, which is the half that has bugs in
# it: a rule that did not match, a message that came out wrong, a chat
# that was not configured yet.
#
# That is also what takes the tunnel out of development. One real
# delivery has to reach this application once — through a tunnel, or
# from another deployment's store — and after that the interesting half
# runs as many times as it takes, with no GitHub, no public hostname and
# no waiting for somebody to push.

(defn find-delivery
  ``The delivery an operator named: the sender's own id (what GitHub
  shows on its deliveries page, and what a support request quotes), or
  this application's row id. Both, because an operator has whichever one
  they happen to be looking at.``
  [ident]
  (def s (string ident))
  (or (deliveries/by-delivery-id s)
      (when-let [n (scan-number s)]
        (when (int? n) (deliveries/by-id n)))))

(defn stored-body
  "The bytes of a kept delivery, or nil when the store no longer holds
  them (a sweep, a bucket the deployment moved off)."
  [row]
  (storage/fetch (row :body-key)))

(defn replay!
  ``Route a kept delivery again, from the bytes as they arrived. Returns
  what `routing/dispatch!` returned — one result per matching rule, so a
  caller can print what it queued and see that a delivery nobody routes
  is a delivery nobody routes.``
  [row]
  (def body
    (or (stored-body row)
        (errorf "the store no longer holds %s (key %s)"
                (row :delivery-id) (row :body-key))))
  (log/info "replaying a kept delivery" :ns log-ns
            :delivery (row :delivery-id) :event (row :event)
            :size (length body))
  (routing/dispatch! row (payload-of body)))
