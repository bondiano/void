(import ../test-support/paths)
(import void/core/log :as log)
(import void/jobs/job :as job)

(log/set-level! "void.jobs" :error)

# -- defjob --------------------------------------------------------------

(job/defjob welcome-mail
  "Greet a new user."
  {:queue :mail :max-attempts 5 :timeout 30 :unique :args}
  [user-id]
  (string "welcome " user-id))

(assert (index-of :welcome-mail (job/defined)) "defjob registers under its own name")
(def d (job/lookup :welcome-mail))
(assert (= :mail (get-in d [:opts :queue])) "with the options it declared")
(assert (= "Greet a new user." (d :doc)) "and its docstring")
(assert (= "welcome 42" (welcome-mail 42))
        "the function stays an ordinary function — calling it runs the work")
(assert (= "welcome 7" ((job/handler d) 7)) "and is what the handler resolves to")

(job/defjob no-opts [x] x)
(assert (= {} (get (job/lookup :no-opts) :opts)) "the options map is optional")
(job/defjob no-doc {:queue :other} [x] x)
(assert (= :other (get-in (job/lookup :no-doc) [:opts :queue])) "so is the docstring")

# late binding: the registry holds the *binding*, not the function
# value, so redefining the function — which is what reloading the
# module does — is live for jobs already queued
(defn welcome-mail [user-id] (string "hello " user-id))
(assert (= "hello 1" ((job/handler (job/lookup :welcome-mail)) 1))
        "a reloaded job runs its new body without anything being re-registered")

# and a job declared where a module binding cannot exist still works,
# through the value captured at declaration time
(defn- declare-nested []
  (job/defjob nested-job [x] (* 10 x))
  (job/lookup :nested-job))
(assert (= 30 ((job/handler (declare-nested)) 3))
        "a job declared inside a function runs — it is merely not reloadable")

(def [ok err] (protect (job/lookup! :never-declared)))
(assert (not ok) "an undeclared job is an error")
(assert (string/find "must import the module" err)
        "and the error says what the worker is missing")

(def [pok _] (protect (job/defjob-form 'broken ["doc" '(+ 1 2)])))
(assert (not pok) "defjob without a parameter list is refused at expansion")

# -- options -------------------------------------------------------------

(each [opts reason]
  [[{:queue "mail"} "a queue that is not a keyword"]
   [{:priority 1.5} "a fractional priority"]
   [{:max-attempts 0} "a job that may never run"]
   [{:timeout 0} "a timeout of nothing"]
   [{:unique :whenever} "a uniqueness mode nobody implements"]
   [{:backoff {:strategy :magic}} "a backoff strategy nobody implements"]
   [{:backoff {:jitter 2}} "more jitter than there is delay"]
   [{:nonsense true} "an option that does not exist"]]
  (def [ok _] (protect (job/normalize-opts "test" opts)))
  (assert (not ok) (string reason " is refused")))

(assert (job/normalize-opts "test" {:unique "my-key"}) "a literal unique key is allowed")
(assert (job/normalize-opts "test" {:group (fn [x] x)}) "so is a group derived from the arguments")

# -- backoff -------------------------------------------------------------

(def fixed {:strategy :fixed :base 10 :max 100 :jitter 0})
(assert (= 10 (job/retry-delay fixed 1)) ":fixed is the same wait every time")
(assert (= 10 (job/retry-delay fixed 5)))

(def linear {:strategy :linear :base 10 :max 1000 :jitter 0})
(assert (= 30 (job/retry-delay linear 3)) ":linear grows by :base")

(def expo {:strategy :exponential :base 1 :max 1000 :jitter 0})
(assert (= 1 (job/retry-delay expo 1)) ":exponential doubles")
(assert (= 4 (job/retry-delay expo 3)))
(assert (= 1000 (job/retry-delay expo 40)) "and is capped at :max")

(def jittered {:strategy :fixed :base 100 :max 1000 :jitter 0.5})
(def waits (map |(job/retry-delay jittered $) (range 1 50)))
(assert (all |(and (>= $ 50) (<= $ 100)) waits)
        "jitter spreads the wait over [(1 - jitter) d, d] and never past it")
(assert (> (length (distinct waits)) 1)
        "and it really is spread — a thousand jobs failing together must not come back together")

# -- canonical keys ------------------------------------------------------

(assert (= (job/canonical {:a 1 :b 2}) (job/canonical {:b 2 :a 1}))
        "a dictionary renders the same however it was built")
(assert (not= (job/canonical "1") (job/canonical 1))
        "and a string cannot collide with a number")
(assert (not= (job/canonical [1 [2]]) (job/canonical [[1] 2]))
        "nor can two different shapes")
(def [cok _] (protect (job/canonical (fn [] 1))))
(assert (not cok) "a function is not plain data and says so")

# -- unique and group keys -----------------------------------------------

(job/defjob keyed {:unique :args :group "tenant"} [a b] [a b])
(def kd (job/lookup :keyed))
(assert (= (job/unique-key kd [1 2] {}) (job/unique-key kd [1 2] {}))
        "the same call keys the same way")
(assert (not= (job/unique-key kd [1 2] {}) (job/unique-key kd [2 1] {}))
        "different arguments key differently")
(assert (= "keyed" (job/unique-key kd [1 2] {:unique :job}))
        ":job keys by name alone")
(assert (nil? (job/unique-key (job/lookup :no-opts) [1] {}))
        "a job that asks for no uniqueness gets none")
(assert (= "tenant" (job/group-key kd [1 2] {})) "the declared group")
(assert (= "other" (job/group-key kd [1 2] {:group "other"})) "the enqueue overrides it")

(job/defjob per-tenant {:group (fn [id _] (string "t-" id))} [tenant-id x] x)
(assert (= "t-9" (job/group-key (job/lookup :per-tenant) [9 :x] {}))
        "a group derived from the arguments is where a tenant id lives")

# -- :needs — what the *work* needs open, not what the worker does -------
#
# A worker is a CLI command and a command starts what it declared. The
# queue is what the worker needs; `:tls/lib` is what an https delivery
# needs, and only the job knows that (examples/hub, ROADMAP 6.6).

(job/defjob posts-somewhere {:queue :notify :needs [:tls/lib]} [x] x)
(job/defjob writes-a-row {:queue :notify :needs [:db/pool]} [x] x)
(job/defjob needs-nothing {:queue :mail} [x] x)

(assert (= [:tls/lib] (get-in (job/lookup :posts-somewhere) [:opts :needs]))
        "a definition keeps what it declared")
(assert (= [:tls/lib :db/pool] (job/needs [:notify]))
        "the worker starts the union over the queues it serves")
(assert (= [] (job/needs [:mail]))
        "and nothing for a queue whose jobs need nothing")
(assert (index-of :tls/lib (job/needs))
        "no queue list is every definition — what a worker with no --queues serves")

(job/defjob on-the-default-queue {:needs [:cache/store]} [x] x)
(assert (index-of :cache/store (job/needs [:default]))
        "a job that named no queue is on the default one")
(assert (index-of :cache/store (job/needs [:other] :other))
        "...whichever queue the running queue calls default")

(def [nok nerr] (protect (job/normalize-opts "job :x" {:needs [:a "b"]})))
(assert (not nok) "a need that is not a component key is refused")
(assert (string/find ":needs" (string nerr)))

(assert (= [:tls/lib :db/pool] (job/needs! :posts-somewhere [:db/pool :tls/lib]))
        "needs! adds without duplicating, and keeps the order it was told")
(assert (= [:tls/lib :db/pool] (get-in (job/lookup :posts-somewhere) [:opts :needs]))
        "...on the definition the worker will read")
(def [uok uerr] (protect (job/needs! :no-such-job [:x])))
(assert (not uok) "a plugin naming a job that does not exist says so at boot")

(print "job-test ok")
