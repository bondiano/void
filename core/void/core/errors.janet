### void/core/errors — errors as data.
###
### Everything else in void is a value: the system map, a schema, the
### config, the route table. An error was the one thing that was not —
### a string from `errorf`, or one of a dozen ad-hoc dictionaries whose
### only common ground was `{:http/status N}`. This module is the
### fourth pillar: one envelope every package raises and every seam
### reads.
###
###     {:void/error :void.db/unique-violation   ; the kind — a namespaced keyword
###      :status 409                             ; the HTTP status it means, when it means one
###      :message "orders_email_key"             ; one sentence for a human
###      :data {:constraint "orders_email_key"}} ; whatever the kind carries, as data
###
### The kind is the branch point (`(= :void.db/unique-violation
### (errors/kind e))` instead of a substring of a message), the status
### is what the HTTP layer answers with, the message is the text, and
### `:data` is the rest. `:http/status` is written alongside `:status`
### so a renderer from before this module — an application's own
### `:void.http/error-renderer`, void/grpc's `codes/failure` — keeps
### reading what it always read; the v1 contract is `{:http/status N}`
### and the envelope is a superset of it.
###
### `of` is the other half: whatever a `try` caught — an envelope, a
### legacy `{:http/status}` dictionary, a bare string from a panic —
### comes back as an envelope, so a seam handles one shape. Kinds are
### declared with `define!` (a default status and a sentence), which
### is what `void errors` and the dash can list; a kind nobody defined
### still works, it just has no default status.
###
### Messages translate the way schema errors do: `(dyn
### :void.errors/messages)` maps a kind to a string or a `(fn [e])`,
### and `message` consults it first — void/i18n binds it per locale.

(def key
  "The key that marks a dictionary as an error envelope; its value is
  the kind."
  :void/error)

(def deadline-message
  "The exact value `ev/deadline` cancels a task with. Matched whole,
  never as a substring: an error that merely mentions a deadline is a
  failure, not a timeout."
  "deadline expired")

# -- kinds ---------------------------------------------------------------

(def- kinds @{})

(defn define!
  ``Declare a kind: its default `:status` (nil for one that has no HTTP
  meaning) and a `:doc` sentence. Re-defining replaces (REPL-friendly).
  Returns the kind.

      (errors/define! :void.db/unique-violation
        {:status 409 :doc "an INSERT or UPDATE hit a unique index"})``
  [kind &opt info]
  (default info {})
  (unless (keyword? kind)
    (errorf "errors/define!: kind must be a keyword, got %q" kind))
  (when-let [s (get info :status)]
    (unless (and (int? s) (<= 100 s 599))
      (errorf "errors/define! %q: :status must be an HTTP status, got %q" kind s)))
  (put kinds kind (freeze {:status (get info :status) :doc (get info :doc)}))
  kind)

(defn defined
  "Every declared kind, sorted, as [kind {:status :doc}] pairs."
  []
  (seq [k :in (sorted (keys kinds))] [k (kinds k)]))

(defn default-status
  "The declared default status of a kind, or nil."
  [kind]
  (get-in kinds [kind :status]))

# -- the envelope --------------------------------------------------------

(defn error?
  "Is this value an envelope — a dictionary carrying `:void/error`?"
  [x]
  (and (dictionary? x) (keyword? (get x key))))

(defn make
  ``The envelope for a kind. `message` is a string (or nil — the
  kind's name stands in), `data` a dictionary or nil, `status` an
  HTTP status overriding the kind's default. Frozen, so it can be
  raised, logged and compared like any other value.``
  [kind &opt message data status]
  (unless (keyword? kind)
    (errorf "errors/make: kind must be a keyword, got %q" kind))
  (unless (or (nil? message) (bytes? message))
    (errorf "errors/make %q: message must be a string, got %q" kind message))
  (unless (or (nil? data) (dictionary? data))
    (errorf "errors/make %q: data must be a dictionary, got %q" kind data))
  (def st (or status (default-status kind)))
  (def out @{key kind
             :message (when message (string message))
             :data (or data {})})
  (when st
    (put out :status st)
    # the v1 spelling, for readers that predate the envelope
    (put out :http/status st))
  (freeze out))

(defn raise
  "Raise an envelope: `(errors/raise :void.db/timeout \"statement cancelled\")`.
  The arguments are `make`'s."
  [kind &opt message data status]
  (error (make kind message data status)))

(defn deadline?
  "Is this caught value the cancellation of an `ev/deadline` task?"
  [x]
  (= deadline-message x))

(defn of
  ``The envelope of whatever a `try` caught:

    * an envelope — itself;
    * a dictionary carrying `:http/status` (an abort from before this
      module, an application's own throw) — an envelope of kind
      `:void.http/abort` with that status, **the original keys kept**:
      a renderer that reads `:void.authz/decision` off the error still
      finds it;
    * the deadline cancellation — `:void/deadline`;
    * a string — `:void/panic` with the string as the message;
    * anything else — `:void/panic` with its description.

  Total: never throws, so a seam can call it on anything.``
  [x]
  (cond
    (error? x) x
    (dictionary? x)
    (let [st (get x :http/status)
          st (when (int? st) st)]
      (freeze (merge x {key :void.http/abort
                        :status (or st 500)
                        :http/status (or st 500)
                        :message (when-let [m (get x :message)] (string m))
                        :data (or (get x :data) {})})))
    (deadline? x) (make :void/deadline deadline-message)
    (bytes? x) (make :void/panic (string x))
    (make :void/panic (describe x))))

# -- reading -------------------------------------------------------------

(defn kind
  "The kind of an envelope (of any caught value, through `of`)."
  [e]
  (get (of e) key))

(defn status
  "The HTTP status an error means: the envelope's, a legacy
  `:http/status`, else 500."
  [e]
  (def env (of e))
  (or (get env :status) (get env :http/status) 500))

(defn data
  "The `:data` of an error, `{}` when it carries none."
  [e]
  (get (of e) :data {}))

(defn message
  ``The sentence for a human. `(dyn :void.errors/messages)` — a
  dictionary kind -> string or (fn [envelope] string) — wins, the way
  `:void.schema/messages` does for validation; then the envelope's own
  `:message`; then the kind's name.``
  [e]
  (def env (of e))
  (def k (get env key))
  (def t (get (dyn :void.errors/messages {}) k))
  (cond
    (function? t) (string (t env))
    (cfunction? t) (string (t env))
    (bytes? t) (string t)
    (get env :message) (get env :message)
    (string k)))

(defn str
  "One line for a log: \"kind: message\"."
  [e]
  (def env (of e))
  (string (get env key) ": " (message env)))

(defn kind?
  "Is `e` an error of this kind (or of any of these kinds)?"
  [e kind-or-kinds]
  (def k (kind e))
  (if (indexed? kind-or-kinds)
    (not (nil? (index-of k kind-or-kinds)))
    (= k kind-or-kinds)))

# -- the kinds every package meets ----------------------------------------

(define! :void/panic
  {:status 500
   :doc "something raised a bare string or a value that is not an envelope — a bug, or a library's own error"})
(define! :void/deadline
  {:status 504
   :doc "an ev/deadline cancelled the task; the exact cancellation value, never a substring"})
(define! :void.http/abort
  {:doc "a dictionary raised with :http/status by code that predates the envelope — the v1 shape, kept"})
(define! :void.schema/invalid
  {:status 422
   :doc "a value did not match its schema; :data {:errors [...]} carries every schema/check error"})
