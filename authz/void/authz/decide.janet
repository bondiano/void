### void/authz/decide — a decision is a value.
###
###     (authz/decide :orders/read {:resource order})
###     # => {:allow false :policy :orders/read :reason "brand 7 ≠ 3"
###     #     :attrs [:subject/brand-id :resource/brand-id] :us 12}
###
### `can?` is `(get (decide …) :allow)` and `ensure!` raises a 403 with
### the same value behind it, so **there is one evaluation path**.
### `explain` does not re-run anything with a flag turned on — it
### prints what enforcement produced. An explanation computed
### separately from the decision is an explanation that will
### eventually be wrong, and it will be wrong exactly when somebody is
### trying to understand a deny.
###
### **The reason never reaches the client.** A 403 body says nothing
### about which attribute failed: the explanation is a description of
### internal state, and an attacker probing an endpoint is precisely
### the person asking. It goes to the decision log and to
### `void authz explain`.
###
### **Several policies mean AND.** Route metadata merges with `:concat`
### (a group's policy plus a route's), and every one of them must
### allow. Evaluation stops at the first deny, so the decision names
### the policy that refused. There is deliberately no "or" — a
### disjunction is expressible as one policy, where it can be read,
### rather than as a shape in metadata where it cannot.

(import void/core/log :as log)
(import void/core/hooks :as hooks)
(import ./policy :as policy)
(import ./context :as context)

(def log-ns "void.authz")

(def decision-hook
  "Core-hook name every decision passes through. void/bus turns
  these into audit events; obs can count them."
  :void.authz/decision)

(var hook-registry
  "The running boot's hook registry, captured at :before-start (the
  tracking `plugin/current-boot` is not set on the inject path, see
  void/auth's init)."
  nil)

(var log-mode
  ``What reaches the log: :deny (default), :all or :none. Allows are
  the overwhelming majority — a page with a hundred rows asks a
  hundred times — and logging them buries the denies nobody wanted.``
  :deny)

(def listeners
  "Decision listeners registered without a manifest, by name."
  @{})

(defn listen!
  "Hear about every decision without contributing a hook — the REPL's
  way, and a test's."
  [name f]
  (put listeners name f)
  f)

(defn unlisten!
  "Remove a listener."
  [name]
  (put listeners name nil))

(defn- emit! [decision]
  (when-let [reg hook-registry]
    (each e (hooks/handlers reg decision-hook)
      (def [ok err] (protect ((e :fn) decision)))
      (unless ok
        (log/warn "decision handler failed" :ns log-ns
                  :handler (e :name) :err (string err)))))
  (each name (sorted (keys listeners))
    (when-let [f (get listeners name)]
      (def [ok err] (protect (f decision)))
      (unless ok
        (log/warn "decision listener failed" :ns log-ns :listener name :err (string err)))))
  (when (or (= :all log-mode)
            (and (= :deny log-mode) (not (decision :allow))))
    (log/info (if (decision :allow) "allow" "deny") :ns log-ns
              :policy (decision :policy)
              :subject (decision :subject)
              :action (decision :action)
              :reason (decision :reason)
              :attrs (decision :attrs)
              :us (decision :us)))
  decision)

(defn- names-of [names]
  (cond
    (nil? names) []
    (keyword? names) [names]
    (indexed? names) names
    (errorf "a policy reference must be a keyword or a list of them, got %q" names)))

(defn decide
  ``Evaluate one policy, or every policy in a list (all must allow).
  Returns the decision value described in the module docstring.

  Options are `context/make`'s (:subject :action :resource :env
  :attrs), or an already-built context under :context.``
  [names &opt opts]
  (default opts {})
  (def wanted (names-of names))
  (def ctx (or (opts :context) (context/make opts)))
  (def t0 (os/clock :monotonic))
  (var denied nil)
  (var reason nil)
  (var last nil)
  (each name wanted
    (when (nil? denied)
      (def p (policy/policy! name))
      (set last name)
      (def out ((p :fn) ctx))
      (cond
        (string? out) (do (set denied name) (set reason out))
        (not out) (do (set denied name) (set reason "policy not satisfied")))))
  (def decision
    {:allow (nil? denied)
     # the policy that refused, or the last one that agreed — a
     # decision always names the policy it is about
     :policy (or denied last)
     :policies (tuple ;wanted)
     :reason reason
     :attrs (tuple ;(context/used ctx))
     :subject (context/subject-string ctx)
     :action (ctx :action)
     :us (math/round (* 1e6 (- (os/clock :monotonic) t0)))})
  (emit! decision))

(defn can?
  "Is it allowed? The boolean projection of `decide` — what a template
  asks before it renders a button, and what a handler asks before it
  writes."
  [names &opt opts]
  ((decide names opts) :allow))

(defn ensure!
  ``Allow, or raise a 403 carrying the decision. The raised value has
  `:http/status 403` so the error renderers answer it the way they
  answer any other status (problem+json under void/rest, the dev page
  in dev); `:message` is deliberately generic, and the reason lives on
  the value for the log rather than in the body.``
  [names &opt opts]
  (def decision (decide names opts))
  (unless (decision :allow)
    (error {:http/status 403
            :message "forbidden"
            :void.authz/decision decision}))
  decision)

(defn explain
  ``The decision, with every policy evaluated rather than stopping at
  the first deny — `void authz explain` and a REPL want the whole
  picture, enforcement wants the first answer. The `:allow` and
  `:reason` of the overall decision are the same either way.``
  [names &opt opts]
  (default opts {})
  (def wanted (names-of names))
  (def ctx (or (opts :context) (context/make opts)))
  (def each-result
    (seq [name :in wanted :let [p (policy/policy! name)]]
      (def t0 (os/clock :monotonic))
      (def out ((p :fn) ctx))
      {:policy name
       :allow (and (not (string? out)) (truthy? out))
       :reason (cond (string? out) out (not out) "policy not satisfied")
       :doc (p :doc)
       :us (math/round (* 1e6 (- (os/clock :monotonic) t0)))}))
  (def denied (find |(not ($ :allow)) each-result))
  {:allow (nil? denied)
   :policy (get denied :policy (last wanted))
   :policies (tuple ;wanted)
   :reason (get denied :reason)
   :results (tuple ;each-result)
   :attrs (tuple ;(context/used ctx))
   :values (freeze (ctx :attrs))
   :subject (context/subject-string ctx)
   :action (ctx :action)
   :us (sum (map |($ :us) each-result))})

(defn print-explanation
  "Print an `explain` result — the body of `void authz explain`."
  [out]
  (printf "subject   %s" (or (out :subject) "(anonymous)"))
  (printf "action    %s" (if (out :action) (string (out :action)) "—"))
  (printf "decision  %s" (if (out :allow) "allow" "DENY"))
  (when (out :reason) (printf "reason    %s" (out :reason)))
  (print "policies")
  (each r (out :results)
    (printf "  %-24s %-6s %4d µs  %s"
            (string (r :policy))
            (if (r :allow) "allow" "DENY")
            (r :us)
            (or (r :reason) (or (r :doc) ""))))
  (if (empty? (out :attrs))
    (print "attributes  (none read)")
    (do
      (print "attributes")
      (each k (out :attrs)
        (printf "  %-24s %q" (string k) (get (out :values) k))))))
