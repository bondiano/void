### void/core/deploy — the shape of the deployment, and the one question
### every store has to answer.
###
### void has a shared replacement for almost everything it keeps in a
### heap: sessions in redis or in the database, a redis cache, the
### db-backed job queue, the db-backed bus, `void/auth-db` for tokens
### and one-time codes. What it did not have was anybody asking. Every
### real check was written against `[:http :workers]`, and that is the
### **vertical** axis: one machine, several processes. Three replicas
### behind a load balancer with `workers: 1` passed every one of them
### and broke silently — a session written on replica A is not on
### replica B, a rate limit of 60 becomes 180, a magic-link code is
### redeemable only on the replica that issued it, `cache/forget`
### clears one third of the caches, and a `defschedule` runs three
### times.
###
### So the question is asked of the deployment, not of the process:
###
###     [:deploy :shape]  :single | :fleet
###
### `:single` is one process (or one machine's prefork family) and
### everything in this file is inert. `:fleet` is "there is a second
### replica" — and under it a store that lives in one process's heap
### is a defect, reported at start with the same shape as
### `authz-http/deny-by-default`: **one error naming every violation**,
### each with the replacement, rather than N boots each fixing one.
###
### The default is the safe one: `:fleet` in `:prod`, `:single` in
### `:dev` and `:test`. Saying otherwise is one line, and a line
### somebody wrote is a decision; a silent default that lets prod
### break on the second replica is not. `[:http :workers] > 1` implies
### `:fleet` whatever the config says — prefork workers are separate
### heaps, so yesterday's check survives as a special case of this one
### rather than as a second mechanism.
###
### **How a plugin takes part.** It contributes to `:void.core/store`
### a declaration with an `:ask` — the vocabulary already existed
### (`void/jobs` has `capabilities :shared?`, `void/bus` has
### `:guarantees {:shared}`), only the caller was missing:
###
###     (plugin/contribute! :void.core/store
###       {:name :void.http/session
###        :what "sessions"
###        :ask (fn [_boot]
###               {:store :memory :shared? false
###                :replacement "..."})})
###
### `:ask` runs when everything is up, so it answers about the store
### this composition actually resolved, not about the one the config
### seems to name. It returns nil when the concern is not configured
### at all (sessions disabled, rate limiting off).
###
### `:shared?` has three values, and the third is the point:
###
###   true         several processes see the same contents
###   false        this heap only — a violation under :fleet
###   :by-design   per-process and *correct* that way, with :why
###                saying so
###
### `:by-design` exists so that the right answers stop looking like
### missing ones. The `void/ws` room registry is per-worker on purpose
### (fan-out between workers is a bus subscriber), the
### `void/pressure` sampler measures this process's RSS and loop lag,
### and the `void/obs` metric registry is aggregated by whatever
### scrapes it. All three show up in `void deploy check` with the
### reason attached, so the next reader fixes something else.

(def config-key
  "The config slice this module reads."
  :deploy)

(def shapes
  "What [:deploy :shape] may say."
  {:single true :fleet true})

(defn default-shape
  "The shape a profile gets when the config does not say: `:fleet` in
  `:prod`, `:single` everywhere else."
  [profile]
  (if (= :prod profile) :fleet :single))

(var- current
  # {:shape :reason} of the most recent bootstrap in this process
  nil)

(defn deployment
  "The resolved deployment of the most recent bootstrap: {:shape
  :reason}, or nil before one has run."
  []
  current)

(defn shape
  "The deployment shape of the most recent bootstrap (`:single` until
  one has run)."
  []
  (get current :shape :single))

(defn fleet?
  "Is this composition deployed as more than one process?"
  []
  (= :fleet (shape)))

(defn resolve!
  ``Work out the deployment from the config `values` and the profile.
  Returns {:shape :reason} and installs it as the process' current
  deployment; a bad `[:deploy :shape]` is pushed onto `errors` (the
  bootstrap batches config failures) and the profile default is used.

  The reason is kept because it is what the report prints, and
  "why does this composition think it is a fleet" has three different
  answers.``
  [values profile &opt errors]
  (default errors @[])
  (def declared (get-in values [config-key :shape]))
  (def workers (get-in values [:http :workers] 1))
  # :auto is "one worker per CPU", which is more than one everywhere
  # this matters
  (def forked? (or (= :auto workers) (and (number? workers) (> workers 1))))
  (when (and (not (nil? declared)) (not (in shapes declared)))
    (array/push errors
                (string/format "[:deploy :shape] must be :single or :fleet, got %q" declared)))
  (def named (when (in shapes declared) declared))
  (def [sh reason]
    (cond
      (= :fleet named) [:fleet "[:deploy :shape] says so"]
      (and (= :single named) forked?)
      [:fleet (string/format "[:deploy :shape] :single, but [:http :workers] %q — prefork workers are separate heaps" workers)]
      (= :single named) [:single "[:deploy :shape] says so"]
      forked? [:fleet (string/format "[:http :workers] %q" workers)]
      (= :prod profile) [:fleet "the :prod default — say [:deploy :shape] :single to deploy one replica"]
      [:single (string/format "the %q default" profile)]))
  (set current {:shape sh :reason reason})
  current)

(defn reset!
  "Forget the resolved deployment — for tests that bootstrap several
  compositions in one process."
  []
  (set current nil)
  nil)

# -- the survey ----------------------------------------------------------

(defn- declarations [boot]
  (or (get-in boot [:extensions :void.core/store :resolved]) []))

(defn needs
  ``The components every declaration wants running before it can
  answer, as one array of keys — what `void deploy check` starts, and
  nothing else. It is deliberately not "the whole system": a survey
  that had to open the listening socket would be a survey nobody could
  run on a machine that is already serving.``
  [boot]
  (def out @[])
  (each decl (declarations boot)
    (each k (get decl :needs [])
      (array/push out k)))
  (distinct out))

(defn- ask-one [decl boot]
  (def [ok answer] (protect ((decl :ask) boot)))
  (cond
    (not ok)
    {:name (decl :name) :what (decl :what) :shared? :unknown
     :error (if (string? answer) answer (string (describe answer)))}
    (nil? answer) nil
    (merge {:name (decl :name) :what (decl :what)} answer)))

(defn survey
  ``Ask every `:void.core/store` declaration about the store this
  composition actually resolved. Returns an array of entries sorted by
  name, each `{:name :what :store :shared? :why :replacement}`; a
  declaration whose concern is not configured contributes nothing, and
  one whose `:ask` threw contributes `:shared? :unknown` with the
  error rather than disappearing.``
  [boot]
  (def out @[])
  (each decl (declarations boot)
    (when-let [entry (ask-one decl boot)]
      (array/push out entry)))
  (sort-by |(string ($ :name)) out)
  out)

(def- not-a-defect
  # `true` is shared, `:by-design` is per-process and right, `:unknown`
  # is an :ask that threw — a broken declaration is its own bug and
  # should not be reported as a per-process store. Everything else,
  # `nil` included, is one: a declaration that does not say lives in a
  # heap, the same default the store contracts take.
  {true true :by-design true :unknown true})

(defn per-process
  "The entries of a survey that are a defect under `:fleet` — the
  stores that live in one process's heap and are not there by design."
  [entries]
  (filter |(not (in not-a-defect (get $ :shared?))) entries))

(defn- line [e]
  (string/format "  %s — the %q store: %s"
                 (e :what) (get e :store :anonymous)
                 (get e :replacement "no shared replacement is declared")))

(defn message
  ``The one error a `:fleet` composition with per-process stores gets:
  every violation, each with what to use instead. One error rather
  than N because fixing them one boot at a time is the failure mode
  this whole file exists to end.``
  [entries reason]
  (def bad (per-process entries))
  (string/format
    (string "this composition is deployed as a fleet (%s) and %d store(s) "
            "live in one process's heap — a second replica would not see "
            "their contents:\n%s\nEach line names what to compose instead. "
            "A deployment that really is one replica says so with "
            "[:deploy :shape] :single.")
    reason (length bad)
    (string/join (map line bad) "\n")))

(defn check!
  ``The gate: under `:fleet`, refuse to run with per-process stores.
  Returns the survey (so a caller can log it) when the composition is
  fit for the shape it declared.``
  [boot]
  (def entries (survey boot))
  (when (and (fleet?) (not (empty? (per-process entries))))
    (error (message entries (get current :reason "resolved"))))
  entries)

# -- the report ----------------------------------------------------------

(defn- verdict [e]
  (case (get e :shared?)
    true "shared"
    :by-design "by design"
    :unknown "no answer"
    "per-process"))

(defn- note [e]
  (case (get e :shared?)
    false (get e :replacement "")
    :by-design (get e :why "")
    :unknown (get e :error "")
    ""))

(defn report
  ``The lines `void deploy check` and the dev banner print: the shape,
  why it is that, and one row per store with its verdict and the note
  that matters (the replacement for a violation, the reason for a
  deliberate per-process store).``
  [boot &opt entries]
  (default entries (survey boot))
  (def dep (or current {:shape :single :reason "not resolved"}))
  (def out @[(string/format "shape   %q (%s)" (dep :shape) (dep :reason))])
  # a composition that keeps nothing is fit for every shape, and saying
  # so twice would be one line of ceremony per boot
  (when (empty? entries)
    (array/push out "stores  none — nothing this composition keeps outlives a request")
    (break out))
  (each e entries
    (array/push out
                (string/trimr
                  (string/format "  %-30s %-10s %-12s %s"
                                 (e :what)
                                 (string/format "%q" (get e :store :anonymous))
                                 (verdict e)
                                 (note e)))))
  (def bad (per-process entries))
  (array/push out
              (cond
                (not (fleet?)) (string/format "ready   not asked — this is a %q deployment" (dep :shape))
                (empty? bad) "ready   yes — every store is shared"
                (string/format "ready   NO — %d store(s) would not survive a second replica" (length bad))))
  out)
