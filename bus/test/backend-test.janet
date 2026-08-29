(import ../test-support/paths)
(import void/bus/backend :as backend)

(defn- minimal [&opt extra]
  (merge @{:name :fake
           :publish! (fn [_] 1)
           :consume! (fn [_ _] @{})
           :stop! (fn [_])}
         (or extra {})))

# -- what a backend must answer ------------------------------------------

(def b (backend/normalize (minimal)))
(assert (= :fake (b :name)))
(assert (function? (b :close)) "the optional keys are filled in, so the router never branches")
(assert (deep= {} ((b :stats))) "including a stats function that answers nothing")

(each missing [:publish! :consume! :stop!]
  (def broken (minimal))
  (put broken missing nil)
  (def [ok err] (protect (backend/normalize broken)))
  (assert (not ok) (string/format "a backend without %q is refused" missing))
  (assert (string/find (string missing) (string err))
          "and the error names the key that is missing"))

(assert (not (first (protect (backend/normalize (minimal {:stats "no"})))))
        "an optional key that is not a function is refused too")

# -- guarantees are declared, and the weakest is the default -------------

(assert (= :at-most-once (get-in b [:guarantees :delivery]))
        "a backend that declares nothing is trusted least")
(assert (not (backend/durable? b)))
(assert (not (backend/shared? b)))
(assert (not (backend/at-least-once? b)))

(def durable
  (backend/normalize
    (minimal {:guarantees {:delivery :at-least-once :ordering :per-group
                           :durable true :shared true}})))
(assert (backend/at-least-once? durable))
(assert (backend/durable? durable))
(assert (backend/shared? durable))

(assert (not (first (protect (backend/normalize (minimal {:guarantees {:delivery :exactly-once}})))))
        "there is no :exactly-once, and claiming it is a load error rather than a lie in a docstring")
(assert (not (first (protect (backend/normalize (minimal {:guarantees {:ordering :total}})))))
        "and no ordering nobody implements")
(assert (not (first (protect (backend/normalize (minimal {:guarantees {:durable "yes"}})))))
        ":durable is a boolean")

# -- capabilities are what the CLI prints --------------------------------

(def caps (backend/capabilities durable))
(assert (= :fake (caps :name)))
(assert (= :at-least-once (caps :delivery)))
(assert (caps :durable))
(assert (caps :encoded) "a backend that says nothing about encoding stores bytes")

# -- the outbox refuses a transport that forgets -------------------------

(assert (backend/require-durable! durable "the transactional outbox"))
(def [ok err] (protect (backend/require-durable! b "the transactional outbox")))
(assert (not ok) "an outbox in front of a forgetful transport is refused")
(assert (string/find "void/bus-db" (string err))
        "and the error names what to compose instead")

# -- factories -----------------------------------------------------------

(def factories
  (tabseq [c :in [{:name :memory :make (fn [_] (minimal))}
                  {:name :db :make (fn [_] (minimal))}]]
    (c :name) (backend/normalize-factory c)))

(assert (= :db ((backend/find-factory factories :db) :name)))
(def [ok2 err2] (protect (backend/find-factory factories :kafka)))
(assert (not ok2) "an unknown backend name is a boot error")
(assert (and (string/find "memory" (string err2)) (string/find "db" (string err2)))
        "listing the ones this composition actually has")

(assert (not (first (protect (backend/normalize-factory {:name :x}))))
        "a factory without :make cannot make anything")
(assert (not (first (protect (backend/normalize-factory {:make (fn [_])}))))
        "and one without a name cannot be named in a config")

(print "void/bus/backend tests OK")
