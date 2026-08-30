### void/auth/store — where users, tokens and one-time codes live
### (ADR-0023 §2).
###
### Three contracts, because void does not get to know an
### application's schema. Each is a plain dictionary of functions,
### produced by a component's `:start`, and each has a memory
### implementation here so that a test — or a single-process
### application with five users in the config — needs no database.
### `void/auth-db` (same package) implements all three over `void/db`.
###
###   :void.auth/user-store       who exists, and what their password
###                               hash is
###   :void.auth/token-store      API tokens, stored as digests
###   :void.auth/challenge-store  magic links and one-time codes, which
###                               must be single-use
###
### The user store is four functions:
###
###   :find    (fn [selector] record|nil)  selector is {:by :email
###                                        :value "a@b.c"} — :by is
###                                        whatever the application
###                                        indexes, and :subject is the
###                                        one every store must answer
###   :secret  (fn [record] phc|nil)       the stored password hash
###   :subject (fn [record] "user:42")     the identity's subject
###   :claims  (fn [record] {...})         optional, defaults to {}
###
### `:find` takes a selector rather than a bare value because "find by
### email" and "find by subject" are the same question asked of
### different columns, and a store that only knew one of them could not
### answer a session (which carries a subject) *and* a login form
### (which carries an email).
###
### The challenge store's `:take` is deliberately not `:get`: a
### one-time code that can be read twice is not one-time, so the
### contract is "hand it over and forget it", and an implementation
### that cannot do that atomically has to say so rather than pretend.
###
### Two of the three contracts also carry `:shared?` — "would a second
### replica see this row" (ADR-0030). It matters for tokens and for
### challenges, and `[:deploy :shape] :fleet` refuses a per-process one
### at start: a magic link issued by replica A and clicked on replica B
### is a login that fails for no reason the user can see, and an API
### token minted on one replica authenticates on one replica. It does
### **not** matter for the user store, and that is not an oversight: the
### in-process user store is seeded from `[:auth :users]`, so every
### replica reads the same configuration and holds the same users. A
### store built out of config is shared by construction.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- require-fns [kind st name required]
  (each k required
    (unless (callable? (get st k))
      (errorf "%s %q: %q must be a function, got %q" kind name k (get st k)))))

# -- user store ----------------------------------------------------------

(defn normalize-user-store
  "Validate a user store and fill in its documented fallbacks."
  [st]
  (unless (dictionary? st)
    (errorf "user store must be a dictionary, got %q" st))
  (def name (get st :name :anonymous))
  (require-fns "user store" st name [:find :subject])
  (freeze
    (merge
      @{:name name
        # a store whose users have no password (SSO only, tokens only)
        # says so by leaving :secret out — the password strategy then
        # fails every login through dummy-verify, which is the right
        # answer and the right timing
        :secret (fn [_] nil)
        :claims (fn [_] {})}
      st)))

(defn memory-user-store
  ``An in-process user store over a table of records, for tests and
  for applications whose user list is configuration. `records` is
  subject -> `{:email :password-hash :claims}`; `index` names the
  extra fields `:find` can look up by (`[:email :username]`).

  The hash lives under `:password-hash` rather than `:secret` because
  `{:secret "NAME"}` is how void/core/config spells an env-var
  reference (ADR-0007) — a record with a `:secret` key in
  `[:auth :users]` would be resolved as one and fail the boot.``
  [records &opt index]
  (default index [:email])
  # freeze, not table/to-struct: the caller may hand over either a
  # table or a struct, and only one of them is accepted by the latter
  (def by-subject (freeze (or records {})))
  (def indexes
    (tabseq [field :in index]
      field (tabseq [[subject rec] :pairs by-subject
                     :when (get rec field)]
              (string (get rec field)) subject)))
  {:name :memory
   :records by-subject
   :find (fn user-find [selector]
           (def by (get selector :by :subject))
           (def value (string (get selector :value)))
           (if (= :subject by)
             (get by-subject value)
             (when-let [table (get indexes by)
                        subject (get table value)]
               (get by-subject subject))))
   # `:password-hash`, not `:secret`: a config value shaped
   # `{:secret "NAME"}` is an env-var reference to void/core/config
   # (ADR-0007), so a store seeded from `[:auth :users]` would have its
   # hashes resolved as environment variables and fail the boot with a
   # message about a variable nobody wrote
   :secret (fn user-secret [rec] (get rec :password-hash))
   :subject (fn user-subject [rec] (get rec :subject))
   :claims (fn user-claims [rec] (get rec :claims {}))})

# -- token store ---------------------------------------------------------

(defn normalize-token-store
  ``Validate an API-token store. Records are {:id :digest :subject
  :name :scopes :expires :created :used}; the store never sees a
  token, only its digest (ADR-0023 §5).``
  [st]
  (unless (dictionary? st)
    (errorf "token store must be a dictionary, got %q" st))
  (def name (get st :name :anonymous))
  (require-fns "token store" st name [:find :put :delete])
  (freeze
    (merge
      @{:name name
        # a store several replicas read; false means "this heap only",
        # which makes a token valid on the process that minted it and
        # nowhere else (ADR-0030)
        :shared? false
        # "when was this token last used" is an audit nicety, not a
        # contract: a store that will not write on every request says so
        # by leaving :touch out
        :touch (fn [_ _] nil)
        :list (fn [_] [])}
      st)))

(defn memory-token-store
  # The inner functions are named `token-put` and friends rather than
  # `put` and `find`: those are core functions, and a named `(fn put
  # ...)` shadows the one its own body needs.
  "An in-process token store — tests, and single-process deployments
  where tokens may die with the process."
  []
  (def rows @{})
  {:name :memory
   :rows rows
   :find (fn token-find [id] (get rows id))
   :put (fn token-put [record] (put rows (record :id) record) record)
   :delete (fn token-delete [id] (def had (not (nil? (get rows id))))
             (put rows id nil) had)
   # the row is replaced rather than mutated: a record may arrive as a
   # struct, and a store that only works with tables is a store that
   # fails on the caller who froze theirs
   :touch (fn token-touch [id at]
            (when-let [r (get rows id)] (put rows id (merge r {:used at})))
            nil)
   :list (fn token-list [subject]
           (sorted-by |($ :id)
                      (filter |(= subject ($ :subject)) (values rows))))})

# -- challenge store -----------------------------------------------------

(defn normalize-challenge-store
  ``Validate a store for magic links and one-time codes. `:take` must
  return the record **and remove it in the same step** — a code that
  can be read twice is not one-time.``
  [st]
  (unless (dictionary? st)
    (errorf "challenge store must be a dictionary, got %q" st))
  (def name (get st :name :anonymous))
  (require-fns "challenge store" st name [:put :take])
  (freeze (merge @{:name name :shared? false :sweep (fn [] nil)} st)))

(defn memory-challenge-store
  "An in-process challenge store. Single-use by construction, and
  per-process — with prefork workers (ADR-0010) or a fleet, a code
  issued by one process cannot be redeemed at another, which is what
  void/auth-db is for and what `[:deploy :shape] :fleet` refuses to
  start without (ADR-0030)."
  []
  (def rows @{})
  (defn now [] (os/time))
  {:name :memory
   :rows rows
   :put (fn challenge-put [id record ttl]
          (put rows id {:record record :expires (+ (now) ttl)})
          id)
   :take (fn challenge-take [id]
           (when-let [row (get rows id)]
             # removed before it is returned, not after: between the two
             # there is no moment at which a second caller could take it
             (put rows id nil)
             (when (> (row :expires) (now)) (row :record))))
   :sweep (fn challenge-sweep []
            (def t (now))
            (each k (seq [[k v] :pairs rows :when (<= (v :expires) t)] k)
              (put rows k nil))
            nil)})

(defn shared?
  "True when several processes see the same rows — the question
  `[:deploy :shape] :fleet` asks of every store it can reach
  (ADR-0030)."
  [st]
  (truthy? (get st :shared?)))
