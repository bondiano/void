(import ../test-support/paths)
(import void/core/log :as log)
(import void/auth/identity :as identity)
(import void/auth/strategy :as strategy)

(log/set-level! "void.auth.strategy" :error)

(defn- id-for [subject] (identity/make subject {:via :test}))

# -- the shape -----------------------------------------------------------

(each bad [{} {:name "session"} {:name :s} {:name :s :authenticate 42}]
  (def [ok] (protect (strategy/normalize bad)))
  (assert (not ok) (string/format "%q is not a strategy" bad)))

(def normalized (strategy/normalize {:name :s :verify (fn [_])}))
(assert (= 100 (normalized :priority)) "a strategy that does not say where it goes lands in the middle")
(assert (not (normalized :cookie)) "and is assumed not to read cookies until it says it does")

# -- the chain -----------------------------------------------------------

(def calls @[])

(strategy/register! {:name :first :priority 10
                     :authenticate (fn [req] (array/push calls :first)
                                     (when (req :first) (id-for "user:1")))})
(strategy/register! {:name :second :priority 20
                     :authenticate (fn [req] (array/push calls :second)
                                     (when (req :second) (id-for "user:2")))})
(strategy/register! {:name :login-only :verify (fn [creds] (id-for "user:3"))})

(assert (deep= [:first :login-only :second] (tuple ;(strategy/known))))
(assert (deep= [:first :second] (tuple ;(map |($ :name) (strategy/request-strategies))))
        "a strategy with no :authenticate is not in the request chain at all — it cannot cost anything")

(array/clear calls)
(assert (nil? (strategy/authenticate @{})) "nobody claims an anonymous request")
(assert (deep= @[:first :second] calls) "and both were asked, in priority order")

(array/clear calls)
(assert (= "user:2" ((strategy/authenticate @{:second true}) :subject)))
(assert (deep= @[:first :second] calls))

(array/clear calls)
(assert (= "user:1" ((strategy/authenticate @{:first true :second true}) :subject))
        "the first strategy to answer wins")
(assert (deep= @[:first] calls) "and the rest are not asked")

# -- narrowing -----------------------------------------------------------

(assert (= "user:2" ((strategy/authenticate @{:first true :second true} [:second]) :subject))
        "a route can name which strategies may answer for it")
(def [ok err] (protect (strategy/authenticate @{} [:typo])))
(assert (not ok) "and a name that is not registered is an error")
(assert (string/find "typo" (string err)))

(set strategy/order [:second :first])
(assert (deep= [:second :first] (tuple ;(map |($ :name) (strategy/request-strategies))))
        "the configured order wins over priority")
(set strategy/order nil)

# -- verify --------------------------------------------------------------

(assert (= "user:3" ((strategy/attempt :login-only {}) :subject)))
(def [ok2] (protect (strategy/attempt :first {})))
(assert (not ok2) "a request strategy cannot verify credentials, and saying so is better than answering nil")
(def [ok3] (protect (strategy/attempt :missing {})))
(assert (not ok3))

# -- what a strategy may not return --------------------------------------

(strategy/register! {:name :liar :authenticate (fn [_] {:sub "user:9"})})
(def [ok4 err4] (protect (strategy/authenticate @{})))
(assert (not ok4) "a strategy that returns something that is not an identity is a bug, and it surfaces as one")
(assert (string/find "liar" (string err4)))
(strategy/deregister! :liar)

# -- an expired identity is not an identity ------------------------------

(strategy/register! {:name :stale :priority 5
                     :authenticate (fn [_] (identity/make "user:old" {:expires 1}))})
(assert (nil? (strategy/authenticate @{})) "an identity that has already expired does not authenticate anybody")
(strategy/deregister! :stale)

# -- challenges ----------------------------------------------------------

(strategy/register! {:name :challenger :priority 1
                     :authenticate (fn [_] nil)
                     :challenge (fn [_] {:status 401 :headers @{"www-authenticate" "Bearer"}})})
(assert (= 401 ((strategy/challenge @{}) :status)))
(strategy/deregister! :challenger)
(assert (nil? (strategy/challenge @{})) "with nobody offering one, the caller renders its own 401")

(print "strategy-test ok")
