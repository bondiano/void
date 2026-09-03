# The deployment shape and the store survey: [:deploy :shape] resolution,
# one error naming every per-process store, and the three answers a store
# may give.
(import ../void/core/plugin :as plugin)
(import ../void/core/system :as system)
(import ../void/core/deploy :as deploy)

# -- the shape -----------------------------------------------------------

(assert (= :single (get (deploy/resolve! {} :dev) :shape))
        "dev is one process until it says otherwise")
(assert (= :single (get (deploy/resolve! {} :test) :shape)))
(assert (= :fleet (get (deploy/resolve! {} :prod) :shape))
        "prod defaults to :fleet — the safe value is the default one")

(assert (= :single (get (deploy/resolve! {:deploy {:shape :single}} :prod) :shape))
        "and opting out of it is one line")
(assert (= :fleet (get (deploy/resolve! {:deploy {:shape :fleet}} :dev) :shape)))

# prefork is a fleet, whatever the config says: yesterday's :workers
# check survives as a special case of this one
(assert (= :fleet (get (deploy/resolve! {:http {:workers 4}} :dev) :shape)))
(assert (= :fleet (get (deploy/resolve! {:http {:workers :auto}} :dev) :shape)))
(assert (= :fleet (get (deploy/resolve! {:deploy {:shape :single}
                                         :http {:workers 2}}
                                        :dev)
                       :shape))
        ":deploy :single cannot talk a prefork family out of being several heaps")
(assert (= :single (get (deploy/resolve! {:http {:workers 1}} :dev) :shape)))

(def errs @[])
(assert (= :single (get (deploy/resolve! {:deploy {:shape :cluster}} :dev errs) :shape)))
(assert (= 1 (length errs)) "a bad shape is a config error, batched like any other")
(assert (string/find "[:deploy :shape]" (first errs)))

# the reason is what the report prints, and it is different every time
(deploy/resolve! {} :prod)
(assert (string/find ":prod default" (get (deploy/deployment) :reason)))
(deploy/resolve! {:http {:workers 3}} :dev)
(assert (string/find ":workers" (get (deploy/deployment) :reason)))

# -- a composition that declares stores ----------------------------------

(defn- store-plugin [name what shared? &opt extra]
  (default extra {})
  (plugin/manifest name
    :version "0.0.1"
    :contributes
    {:void.core/store
     [(merge {:name (keyword (string "test/" what))
              :what what
              :ask (fn [_boot] (merge {:store (if shared? :shared :memory)
                                       :shared? shared?
                                       :replacement (string "compose the shared " what)}
                                      extra))}
             {})]}))

(def sessions (store-plugin :test/sessions "sessions" false))
(def codes (store-plugin :test/codes "one-time codes" false))
(def queue (store-plugin :test/queue "the job queue" true))
(def rooms
  (plugin/manifest :test/rooms
    :version "0.0.1"
    :contributes
    {:void.core/store
     [{:name :test/rooms
       :what "websocket rooms"
       :ask (fn [_boot] {:store :process :shared? :by-design
                         :why "a connection lives in the process holding its socket"})}]}))

# :single — the whole mechanism is inert
(def single (plugin/start! {:plugins [sessions codes queue rooms] :profile :dev}))
(assert (= :single (deploy/shape)))
(def entries (single :stores))
(assert (= 4 (length entries)) "every declaration is surveyed even under :single")
(assert (= 2 (length (deploy/per-process entries))))
(plugin/shutdown! single)

# :fleet — one error, naming all of them, each with its replacement
(def [ok err]
  (protect (plugin/start! {:plugins [sessions codes queue rooms]
                           :profile :prod})))
(assert (not ok) "a fleet composition with per-process stores does not start")
(def msg (string err))
(assert (string/find "2 store(s)" msg) (string "expected both violations at once, got: " msg))
(assert (string/find "sessions" msg))
(assert (string/find "one-time codes" msg))
(assert (string/find "compose the shared sessions" msg) "each line names the replacement")
(assert (string/find "compose the shared one-time codes" msg))
(assert (not (string/find "the job queue" msg)) "a shared store is not a violation")
(assert (not (string/find "websocket rooms" msg))
        "and neither is one that is per-process by design")
(assert (string/find "[:deploy :shape] :single" msg)
        "the way out is in the message: say the deployment is one replica")

# the same composition with shared replacements starts
(def fleet
  (plugin/start! {:plugins [(store-plugin :test/sessions "sessions" true)
                            (store-plugin :test/codes "one-time codes" true)
                            queue rooms]
                  :profile :prod}))
(assert (= :fleet (deploy/shape)))
(assert (empty? (deploy/per-process (fleet :stores))))
(plugin/shutdown! fleet)

# -- the report ----------------------------------------------------------

(def boot (plugin/bootstrap {:plugins [sessions queue rooms] :profile :prod} true))
(def lines (deploy/report boot))
(def text (string/join lines "\n"))
(assert (string/find ":fleet" text))
(assert (string/find "by design" text))
(assert (string/find "a connection lives in the process" text)
        "the reason travels with the row, so nobody tries to fix it")
(assert (string/find "ready   NO" text))

(deploy/resolve! {} :dev)
(assert (string/find "not asked" (string/join (deploy/report boot) "\n"))
        "under :single the report says the question was not put")

# -- :needs --------------------------------------------------------------

(def with-needs
  (plugin/manifest :test/needy
    :version "0.0.1"
    :components [(system/component :test/thing :start (fn [_ _] @{}))]
    :contributes
    {:void.core/store
     [{:name :test/needy :what "a thing" :needs [:test/thing]
       :ask (fn [boot]
              (when (get-in boot [:system :instances :test/thing])
                {:store :thing :shared? true}))}]}))

(def nb (plugin/bootstrap {:plugins [with-needs] :profile :prod} true))
(assert (= [:test/thing] (tuple ;(deploy/needs nb)))
        "the survey knows which components it has to start, and no others")

# an :ask that throws is reported, not swallowed
(def broken
  (plugin/manifest :test/broken
    :version "0.0.1"
    :contributes
    {:void.core/store
     [{:name :test/broken :what "a broken store"
       :ask (fn [_] (error "no answer"))}]}))
(def bb (plugin/bootstrap {:plugins [broken] :profile :dev} true))
(def surveyed (deploy/survey bb))
(assert (= 1 (length surveyed)))
(assert (= :unknown (get (first surveyed) :shared?)))
(assert (string/find "no answer" (get (first surveyed) :error)))

# a declaration that forgets to say is taken to live in a heap — the
# same default the store contracts take
(def silent
  (plugin/manifest :test/silent
    :version "0.0.1"
    :contributes
    {:void.core/store
     [{:name :test/silent :what "a silent store"
       :ask (fn [_] {:store :whatever})}]}))
(def sb (plugin/bootstrap {:plugins [silent] :profile :prod} true))
(assert (= 1 (length (deploy/per-process (deploy/survey sb))))
        "silence is not an answer, and is not read as one")

# a broken :ask is a bug in the declaration, not a per-process store
(assert (empty? (deploy/per-process surveyed))
        "an :ask that threw is reported, but does not stop a fleet on its own")

(deploy/reset!)
(print "deploy-test: all assertions passed")
