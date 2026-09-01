### void/http/middleware — middleware phases and chain building
### (SPEC.md part II §1.4).
###
### Middleware is a wrapper (fn [handler] handler') registered through
### the :void.http/middleware extension point with a numeric phase —
### Spring Ordered, as data. Phase constants leave room to slot in
### between (3500); the tie-break at an equal phase is the contributing
### plugin's name, then the middleware name, so the chain order is
### deterministic across boots. A contribution marked :named is not
### applied globally — a route opts in by listing it in the
### :void.http/middleware metadata key. A :when predicate is evaluated
### against the route's merged metadata once, at table-build time: a
### middleware that declines a route is not in that route's chain at
### all — nothing is decided on the hot path.

(def phases
  "The standard phase constants (SPEC part II §1.4)."
  {:panic-guard 0
   :observability 1000
   :parsing 2000
   :session 3000
   :auth 4000
   :authz 5000
   :validation 6000
   :business 7000
   :response 9000})

(def phase/panic-guard (phases :panic-guard))
(def phase/observability (phases :observability))
(def phase/parsing (phases :parsing))
(def phase/session (phases :session))
(def phase/auth (phases :auth))
(def phase/authz (phases :authz))
(def phase/validation (phases :validation))
(def phase/business (phases :business))
(def phase/response (phases :response))

# -- request-lifecycle stages (ADR-0016) ---------------------------------
#
# A stage is a reserved slot on this same phase scale — hooks compile
# into the one route chain as thin wrappers; a route with no hooks on a
# stage pays nothing (no wrapper). Request-side hooks are
# (fn [request]) — nil/request continues, a response table (:status)
# short-circuits: the remaining chain and handler are skipped and the
# response unwinds through the OUTER wrappers (:on-send always sees
# it). Response-side hooks are (fn [request response]) -> response.
# :on-response / :on-error / :on-timeout live outside the chain — the
# server, the panic guard and the inject path call them.

(def stage-slots
  "In-chain stage -> phase slot."
  {:on-send 500
   :on-request 1500
   :pre-parsing 1900
   :pre-validation 5900
   :pre-serialization 9800
   :pre-handler 9900})

(def request-stages
  "In-chain stages whose hooks see (fn [request])."
  {:on-request true :pre-parsing true :pre-validation true :pre-handler true})

(def out-of-chain-stages
  "Stages the transport calls directly."
  {:on-response true :on-error true :on-timeout true})

(def stages
  "Every valid stage name."
  (freeze (merge (tabseq [k :keys stage-slots] k true) out-of-chain-stages)))

(defn- response-map? [x]
  (and (dictionary? x) (not (nil? (x :status)))))

(defn stage-wrapper
  ``The synthetic middleware entry for one in-chain stage of one route
  ({:name :phase :wrap}), or nil when `hooks` (tuple of callables) is
  empty — an empty stage costs nothing.``
  [stage hooks]
  (when (and hooks (not (empty? hooks)))
    (def slot (or (get stage-slots stage)
                  (errorf "%q is not an in-chain stage" stage)))
    {:name (keyword "void.http.stage/" stage)
     :phase slot
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

(defn sort-contributions
  ``Deterministic chain order for middleware contributions of the shape
  {:plugin <keyword> :value {:name :phase :wrap ...}}: ascending phase,
  ties broken by plugin name, then middleware name.``
  [contribs]
  (sorted-by
    (fn [c] [(get-in c [:value :phase] phase/business)
             (string (get c :plugin ""))
             (string (get-in c [:value :name] ""))])
    contribs))

(defn select
  ``The middleware that apply to one route: global (un-:named)
  contributions whose :when predicate (if any) accepts the route's
  merged metadata, plus the :named ones the route lists under
  :void.http/middleware. An unknown name in that list is an error —
  table build fails fast. Returns the sorted contribution values.``
  [contribs route-meta]
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
  (seq [c :in (sort-contributions contribs)
        :let [v (c :value)]
        :when (if (v :named) (in wanted (v :name)) true)
        :when (if-let [pred (v :when)] (pred route-meta) true)]
    v))

(defn chain
  ``Compose selected middleware values around a handler: the lowest
  phase ends up outermost. Returns the composed (fn [request]
  response).``
  [selected handler]
  (var h handler)
  (loop [i :down-to [(dec (length selected)) 0]]
    (set h (((selected i) :wrap) h)))
  h)
