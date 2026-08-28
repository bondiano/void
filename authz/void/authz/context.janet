### void/authz/context — the decision context, with attributes that are
### pulled rather than pushed (ADR-0024 §2).
###
### A context is `{:subject <identity> :action :resource :env}` plus a
### memo table. Policies do not read those fields directly; they ask:
###
###     (authz/attr ctx :subject/brand-id)
###     (authz/attr ctx :resource/owner-id)
###
### and the value is produced **on first use**. This is the whole reason
### the module exists. A route whose policy only looks at a role must
### not pay for the database query that answers "which brand does this
### user belong to", and a route whose policy needs it must pay once
### even if three policies ask. Pushing every attribute into every
### context makes the first case impossible; pulling makes both cheap.
###
### Where an attribute comes from, in order:
###
###   1. the memo — resolved once per decision
###   2. a `:void.authz/provider` contribution whose `:for` matches the
###      namespace (`:subject`, `:resource`, `:env`) and whose `:keys`,
###      if it names any, include this one
###   3. the built-in fallbacks: `:subject/*` reads the identity's
###      claims, plus `:subject/id` and `:subject/kind` from the subject
###      string; `:resource/*` reads the resource dictionary (or an
###      entity instance) by the bare key; `:env/*` reads the env map
###
### The fallbacks are what make the common case need no configuration:
### `(attr ctx :resource/author-id)` over a row from the database is
### exactly `(get row :author-id)`, and a provider is only written when
### the answer is not already in hand.
###
### **The memo is per decision, and that is a trade.** An attribute that
### changes while a request is being served is not re-read. The
### alternative — resolving on every mention — makes the cost of a
### policy depend on how many times it happens to mention an attribute,
### which is worse to reason about than a value that is stable for the
### length of one decision.

(import void/core/log :as log)

(def log-ns "void.authz.context")

(def identity-dyn
  ``The dyn key `void/auth` publishes the current identity under. Read
  by name rather than by importing the package: an application with
  its own authentication binds the same key and gets the same
  authorization (ADR-0024, the trick `void/pressure-http` uses for
  `:void.obs/endpoint`).``
  :void.auth/identity)

(def providers
  "Registered attribute providers, in resolution order."
  @[])

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn normalize-provider
  "Validate a provider: {:name :for :fn :keys? :doc?}."
  [p]
  (unless (dictionary? p)
    (errorf "an attribute provider must be a dictionary, got %q" p))
  (def name (get p :name))
  (unless (keyword? name)
    (errorf "an attribute provider needs a keyword :name, got %q" name))
  (def for (get p :for))
  (unless (index-of for [:subject :resource :env])
    (errorf "provider %q: :for must be :subject, :resource or :env, got %q" name for))
  (unless (callable? (get p :fn))
    (errorf "provider %q: :fn must be a function, got %q" name (get p :fn)))
  (when-let [keys (get p :keys)]
    (unless (and (indexed? keys) (all keyword? keys))
      (errorf "provider %q: :keys must be a list of keywords, got %q" name keys)))
  (freeze p))

(defn register-provider!
  "Add an attribute provider (replacing one of the same name)."
  [p]
  (def n (normalize-provider p))
  (def i (find-index |(= (n :name) ($ :name)) providers))
  (if i (put providers i n) (array/push providers n))
  (n :name))

(defn deregister-provider!
  "Remove a provider by name."
  [name]
  (def i (find-index |(= name ($ :name)) providers))
  (when i (array/remove providers i))
  nil)

(defn provider-names
  "Every registered provider, in resolution order."
  []
  (map |($ :name) providers))

(defn split-key
  ``Split :subject/brand-id into [:subject :brand-id]. A key without a
  namespace is an error: an attribute nobody can tell apart from
  another group's is how a policy comes to read the wrong thing.``
  [key]
  (def s (string key))
  (def i (first (string/find-all "/" s)))
  (unless i
    (errorf "attribute %q must be namespaced — :subject/…, :resource/… or :env/…" key))
  [(keyword (string/slice s 0 i)) (keyword (string/slice s (inc i)))])

(defn make
  ``Build a decision context. `opts`:

    :subject   the identity (defaults to the one in the dyn)
    :action    what is being attempted, for policies that branch on it
    :resource  the thing being acted on — a row, an entity, anything
    :env       request-shaped facts (ip, time, tenant)
    :attrs     attributes known up front, which skip resolution``
  [&opt opts]
  (default opts {})
  @{:subject (if (in opts :subject) (opts :subject) (dyn identity-dyn))
    :action (get opts :action)
    :resource (get opts :resource)
    :env (get opts :env {})
    :attrs (merge @{} (get opts :attrs {}))
    # every attribute this decision actually looked at, in order —
    # `explain` prints it, and it is how a policy's cost is read
    :used @[]})

(defn- subject-fallback [ctx bare]
  (def id (ctx :subject))
  (when id
    (case bare
      :subject (get id :subject)
      :kind (let [s (string (get id :subject ""))
                  i (first (string/find-all ":" s))]
              (when i (keyword (string/slice s 0 i))))
      :id (let [s (string (get id :subject ""))
                i (first (string/find-all ":" s))]
            (if i (string/slice s (inc i)) s))
      :via (get id :via)
      (get-in id [:claims bare]))))

(defn- resource-fallback [ctx bare]
  (when-let [r (ctx :resource)]
    (when (dictionary? r) (get r bare))))

(defn- env-fallback [ctx bare]
  (get-in ctx [:env bare]))

(defn- from-providers [ctx group key]
  (var found nil)
  (each p providers
    (when (and (nil? found)
               (= group (p :for))
               (or (nil? (p :keys)) (index-of key (p :keys))))
      (def [ok attrs] (protect ((p :fn) ctx)))
      (cond
        (not ok)
        (do (log/warn "attribute provider failed" :ns log-ns
                      :provider (p :name) :err (string attrs))
            (error attrs))

        (dictionary? attrs)
        (do
          # everything the provider returned is memoized, not only the
          # key that was asked for: a provider that went to the database
          # for a row should not be called again for its neighbour
          (eachp [k v] attrs
            (def full (if (string/find "/" (string k)) k (keyword (string group) "/" (string k))))
            (put (ctx :attrs) full v))
          (when (in (ctx :attrs) key) (set found true))))))
  nil)

(defn attr
  ``One attribute of the context, resolved on first use and memoized
  for the rest of this decision. Namespaced keys only:
  `:subject/brand-id`, `:resource/owner-id`, `:env/ip`.``
  [ctx key &opt default]
  (def [group bare] (split-key key))
  (array/push (ctx :used) key)
  (if (in (ctx :attrs) key)
    (get (ctx :attrs) key default)
    (do
      (from-providers ctx group key)
      (unless (in (ctx :attrs) key)
        (put (ctx :attrs) key
             (case group
               :subject (subject-fallback ctx bare)
               :resource (resource-fallback ctx bare)
               :env (env-fallback ctx bare)
               nil)))
      (def v (get (ctx :attrs) key))
      (if (nil? v) default v))))

(defn used
  "The attributes this decision looked at, in order and without
  repeats — the profile of a policy, and what `explain` prints."
  [ctx]
  (def seen @{})
  (seq [k :in (ctx :used) :when (not (in seen k)) :before (put seen k true)] k))

(defn subject
  "The identity behind a context, or nil for an anonymous decision."
  [ctx]
  (ctx :subject))

(defn subject-string
  "The subject string, or nil."
  [ctx]
  (when-let [id (ctx :subject)] (get id :subject)))
