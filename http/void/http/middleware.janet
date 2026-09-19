### void/http/middleware — middleware placement and chain building.
###
### Middleware is a wrapper (fn [handler] handler') registered through
### the :void.http/middleware extension point. It says where it runs
### with edges — `:after` and `:before` a named anchor of the chain
### (`anchors`) or a named neighbour — and one sort (void/core/order)
### turns the edges into the chain order, once per table build, the
### same for every route and every boot. A neighbour may be a
### middleware of the contributing plugin, of void/http, or of a plugin
### the contributor requires; an anchor is always there, which is what
### lets two plugins that do not know each other agree on a place. A
### contribution marked :named is not applied globally — a route opts
### in by listing it in the :void.http/middleware metadata key. A :when
### predicate is evaluated against the route's merged metadata once, at
### table-build time: a middleware that declines a route is not in
### that route's chain at all — nothing is decided on the hot path. A
### contribution marked :route-aware has its :wrap called as (fn
### [handler route-meta]) with that same merged metadata, so what a
### wrapper needs from the route (a rate spec, a schema, a cache
### policy) is computed once, in the closure, and never read off the
### request.

(import void/core/order :as order)

# -- anchors ---------------------------------------------------------------
#
# The chain's named places, outermost first. Each one runs before the
# next; a middleware sits between two of them, and the anchors between
# groups of plugins that do not require each other (authenticated,
# scoped, verified, loaded, authorized, validated, responding) are
# what those plugins agree on instead of a number. A stage anchor is
# where that stage's hooks run on a route that has any; every anchor
# a route has nothing at is simply not in its chain.

(def anchors
  "The :void.http/middleware anchors, outermost first."
  [:void.http/guarded
   :void.http.stage/on-send
   :void.http.stage/on-request
   :void.http.stage/pre-parsing
   :void.http/authenticated
   :void.http/scoped
   :void.http/verified
   :void.http/loaded
   :void.http/authorized
   :void.http.stage/pre-validation
   :void.http/validated
   :void.http/responding
   :void.http.stage/pre-serialization
   :void.http.stage/pre-handler])

(def edge-anchors
  "The :void.http/edge anchors: inside `scoped`, a request has its
  locale scope."
  [:void.http.edge/scoped])

# -- request-lifecycle stages --------------------------------------------
#
# A stage is an anchor of the chain — hooks compile into the one route
# chain as a thin wrapper at that anchor; a route with no hooks on a
# stage pays nothing (no wrapper). Request-side hooks are
# (fn [request]) — nil/request continues, a response table (:status)
# short-circuits: the remaining chain and handler are skipped and the
# response unwinds through the OUTER wrappers (:on-send always sees
# it). Response-side hooks are (fn [request response]) -> response.
# :on-response / :on-error / :on-timeout live outside the chain — the
# server, the panic guard and the inject path call them.
#
# The stages are a contract (ADR-0016, refined by ADR-0045 and
# ADR-0051), and :on-send has a consequence worth stating: it sees only
# the responses that reached its anchor. A middleware that refuses
# *outside* it — void/pressure's 503, void/security's address-keyed
# 429 — does so precisely so that a refusal costs nothing, and its
# response never passes an :on-send hook. What must see every response
# a route produced is :on-response (out of chain, called by the
# transport); what must see every response this process emits, a 404
# and a rendered 500 included, is a :void.http/edge wrapper.

(def stage-anchors
  "In-chain stage -> the anchor its hooks run at."
  {:on-send :void.http.stage/on-send
   :on-request :void.http.stage/on-request
   :pre-parsing :void.http.stage/pre-parsing
   :pre-validation :void.http.stage/pre-validation
   :pre-serialization :void.http.stage/pre-serialization
   :pre-handler :void.http.stage/pre-handler})

(def request-stages
  "In-chain stages whose hooks see (fn [request])."
  {:on-request true :pre-parsing true :pre-validation true :pre-handler true})

(def out-of-chain-stages
  "Stages the transport calls directly."
  {:on-response true :on-error true :on-timeout true})

(def stages
  "Every valid stage name."
  (freeze (merge (tabseq [k :keys stage-anchors] k true) out-of-chain-stages)))

(defn- response-map?
  {:params [:any] :ret :boolean :narrows {:status :any & r}}
  "Is `x` a response table — a dictionary carrying a non-nil :status?
  What a request-side hook's return value is checked against to tell
  a short-circuiting response from a plain nil/request continuation."
  [x]
  (and (dictionary? x) (not (nil? (x :status)))))

(defn stage-wrapper
  {:params [:keyword [(or :function :cfunction)]]
   :ret HttpMiddleware?
   :throws [:string]}
  ``The synthetic middleware entry for one in-chain stage of one route
  ({:name <the stage's anchor> :wrap}), or nil when `hooks` (tuple of
  callables) is empty — an empty stage costs nothing.``
  [stage hooks]
  (when (and hooks (not (empty? hooks)))
    {:name (or (get stage-anchors stage)
               (errorf "%q is not an in-chain stage" stage))
     :wrap
     (if (get request-stages stage)
       (fn [handler]
         (fn request-stage [req]
           (var out nil)
           (each h hooks
             (when (nil? out)
               (def r (h req))
               (when (response-map? r) (set out r))))
           (or out (handler req))))
       (fn [handler]
         (fn response-stage [req]
           (var resp (handler req))
           (each h hooks
             (def r (h req resp))
             (when (dictionary? r) (set resp r)))
           resp)))}))

# -- placement: edges to anchors and neighbours ---------------------------

(def- phase-removed
  "What a leftover :phase is told."
  "has :phase, which was removed in ADR-0051: place it with :after/:before an anchor or a neighbour")

(defn placement-check
  {:params [[:keyword] :string]
   :ret (fn [[{:name :keyword & r}]] :any)}
  ``The :validate of a point ordered by edges, over its `point-anchors`:
  a contribution with a leftover :phase, an edge to a name nothing
  has, a contribution tied to no anchor or a cycle fails the boot —
  dry-run included — rather than a table build. Whether a neighbour
  belongs to a required plugin is the table build's to check: a
  contribution value does not know its plugin.``
  [point-anchors what]
  (fn check-placement [values]
    (def stale (filter |(not (nil? ($ :phase))) values))
    (unless (empty? stale)
      (errorf "%s %s"
              (string/join (map |(string/format "%s %q" what ($ :name)) stale) ", ")
              phase-removed))
    (order/sort values {:anchors point-anchors :what what})
    nil))

(defn order
  {:params [[HttpMiddlewareContribution]
            (or {:anchors (or [:keyword] :nil) :what :string?
                 :requires (or {:keyword :any} :nil)}
                :nil)]
   :ret @[(or HttpMiddlewareContribution HttpAnchor)]
   :throws [:string]}
  ``Contributions ({:plugin :value}) in the order their edges give,
  with each anchor in its place as {:name <anchor> :anchor true} —
  once per table build. Options: :anchors (default `anchors`), :what
  (default "middleware") and :requires, plugin -> its manifest's
  :requires, which confines a contribution's neighbours to its own
  plugin, void/http and the plugins it requires (nil skips that check
  — a bare table build). Every error — an unknown name, an unrequired
  plugin's middleware, a contribution placed nowhere — at once; a
  cycle prints its path.``
  [contribs &opt opts]
  (def opts (or opts {}))
  (def by-name (tabseq [c :in contribs] (get-in c [:value :name]) c))
  (map |(if ($ :anchor) $ (in by-name ($ :name)))
       (order/sort (map |(merge ($ :value) {:plugin ($ :plugin)}) contribs)
                   {:anchors (get opts :anchors anchors)
                    :what (get opts :what "middleware")
                    :owner :void/http
                    :requires (opts :requires)})))

(defn describe
  {:params [HttpMiddlewareContribution]
   :ret HttpChainStep}
  ``One chain step as data, for explain-route and `void routes --chain`:
  {:name :plugin :stage? :after? :before?} — :stage true marks a stage
  wrapper at its anchor, :after/:before are the edges the contribution
  was placed by.``
  [c]
  (def v (c :value))
  (freeze
    (merge {:name (v :name) :plugin (c :plugin)}
           (if (c :stage) {:stage true} {})
           (if (nil? (v :after)) {} {:after (v :after)})
           (if (nil? (v :before)) {} {:before (v :before)}))))

(defn select
  {:params [[(or HttpMiddlewareContribution HttpAnchor)] {:keyword :any}]
   :ret {:selected [HttpMiddlewareContribution] :declined [HttpChainStep]}
   :throws [:string]}
  ``The middleware that apply to one route, out of `ordered` (what
  `order` answers; anchors are passed over): global (un-:named)
  contributions whose :when predicate (if any) accepts the route's
  merged metadata, plus the :named ones the route lists under
  :void.http/middleware. An unknown name in that list is an error —
  table build fails fast. Returns {:selected <contributions, in order>
  :declined [{:name :plugin :reason ...} ...]} — the declined are kept
  so that a route can say why a middleware is not in its chain:
  :reason :named (the route did not list it) or :when (the predicate
  refused the route's metadata).``
  [ordered route-meta]
  (def contribs (filter |(nil? ($ :anchor)) ordered))
  (def by-name (tabseq [c :in contribs] (get-in c [:value :name]) c))
  (def wanted
    (tabseq [n :in (get route-meta :void.http/middleware [])] n true))
  (each n (sorted (keys wanted))
    (unless (in by-name n)
      (errorf "route %q selects unknown middleware %q (known: %s)"
              (get route-meta :name)
              n (string/join (map |(string/format "%q" $)
                                  (sorted (keys by-name)))
                             " "))))
  (defn verdict
    {:params [HttpMiddlewareContribution] :ret (or :keyword :nil)}
    "Why the route declines `c`, or nil when `c` is in its chain."
    [c]
    (def v (c :value))
    (cond
      (and (v :named) (not (in wanted (v :name)))) :named
      (and (v :when) (not ((v :when) route-meta))) :when))
  (def verdicts (map verdict contribs))
  {:selected (tuple ;(seq [[c r] :in (map tuple contribs verdicts) :unless r] c))
   :declined (tuple ;(seq [[c r] :in (map tuple contribs verdicts) :when r]
                       (merge (describe c) {:reason r})))})

(defn splice
  {:params [[(or HttpMiddlewareContribution HttpAnchor)]
            [HttpMiddlewareContribution]
            {:keyword HttpMiddleware}]
   :ret @[HttpMiddlewareContribution]}
  ``One route's chain steps, outermost first: `ordered` (what `order`
  answers) with each anchor replaced by the route's stage wrapper at
  it (`wrappers`, anchor -> wrapper) or dropped when it has none, and
  each contribution kept when it is `selected`.``
  [ordered selected wrappers]
  (def keep (tabseq [c :in selected] (get-in c [:value :name]) true))
  (seq [x :in ordered
        :let [step (if (x :anchor)
                     (when-let [w (in wrappers (x :name))]
                       {:plugin :void/http :value w :stage true})
                     (when (in keep (get-in x [:value :name])) x))]
        :when step]
    step))

(def reasons
  "Why a middleware is not in a route's chain, as text."
  {:named ":named — the route does not list it under :void.http/middleware"
   :when ":when declined the route's metadata"})

(defn chain
  {:params [[HttpMiddleware] HttpHandler (or {:keyword :any} :nil)]
   :ret HttpHandler}
  ``Compose selected middleware values around a handler, the first
  one outermost. A value marked :route-aware gets the route's
  merged metadata as the second argument of its :wrap — at build time,
  once; every other :wrap is called with the handler alone. Returns
  the composed (fn [request] response).``
  [selected handler &opt route-meta]
  (default route-meta {})
  (var h handler)
  (loop [i :down-to [(dec (length selected)) 0]]
    (def m (selected i))
    (set h (if (m :route-aware)
             ((m :wrap) h route-meta)
             ((m :wrap) h))))
  h)
