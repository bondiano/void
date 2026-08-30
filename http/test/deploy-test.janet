# The fleet gate as void/http meets it (ADR-0030). Memory sessions are
# not an error any more — they are an error *under a deployment shape
# that has a second replica*, and prefork is one way to be one, which
# is what used to be the whole check.
(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/deploy :as deploy)
(import void/test :as test)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)

(defn home [_req] (ring/text 200 "ok"))

(def app
  (plugin/manifest 'test/deploy-app
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes (router/routes
                                         (router/GET "/" 'home {:name :home}))
                               :env (router/env-ref (curenv))}]}))

(def shared-sessions
  (plugin/manifest 'test/shared-sessions
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/session-store
     [{:name :test-shared
       :make (fn [_] {:name :test-shared
                      :load (fn [_] nil)
                      :save (fn [id _ _] id)
                      :delete (fn [_] nil)
                      :sweep (fn [] nil)})
       :shared? true}]}))

(defn- start [plugins profile http-cfg]
  # :only [:http/kernel] — everything the request path needs and not
  # the listener, so nothing here opens a port (and :workers 2 does not
  # fork this test suite)
  (test/start! {:plugins plugins
                :profile profile
                :only [:http/kernel]
                :config {:cli {:http (merge {:session {:enabled true}} http-cfg)}}}))

# -- :single: sessions in a heap are fine, and always were ----------------

(def single (start [http/manifest app] :dev {}))
(assert (= :single (deploy/shape)))
(def entry (find |(= :void.http/session ($ :name)) (single :stores)))
(assert entry "the session store declares itself")
(assert (= :memory (entry :store)))
(assert (false? (entry :shared?)))
(test/stop! single)

# -- :fleet: they are not -------------------------------------------------

(def [ok err] (protect (start [http/manifest app] :prod {})))
(assert (not ok) "memory sessions do not survive a second replica, and :prod is a fleet")
(def msg (string err))
(assert (string/find "sessions" msg))
(assert (string/find "void/redis-http" msg) "the message names a replacement")
(assert (string/find "void/db-http" msg) "both of them")
(assert (string/find "[:deploy :shape] :single" msg)
        "and the way out, for a deployment that really is one replica")

# -- prefork is a fleet: the old :workers check is now a special case -----

(def [ok2 err2] (protect (start [http/manifest app] :dev {:workers 2})))
(assert (not ok2) ":workers 2 still refuses memory sessions")
(assert (string/find "sessions" (string err2)))
(assert (string/find ":workers" (string err2))
        "and the reason says which key made this a fleet")

# a single worker in :dev is not a fleet, and says nothing
(def one-worker (start [http/manifest app] :dev {:workers 1}))
(assert (= :single (deploy/shape)))
(test/stop! one-worker)

# -- a shared store starts under either shape -----------------------------

(def fleet (start [http/manifest app shared-sessions] :prod
                  {:session {:enabled true :store :test-shared}}))
(assert (= :fleet (deploy/shape)))
(def e (find |(= :void.http/session ($ :name)) (fleet :stores)))
(assert (= :test-shared (e :store)))
(assert (true? (e :shared?)))
(assert (empty? (deploy/per-process (fleet :stores)))
        "a shared session store is what a fleet needs, and nothing else complains")
(test/stop! fleet)

# -- an application without sessions has nothing to answer for ------------

(def sessionless
  (test/start! {:plugins [http/manifest app] :profile :prod :only [:http/kernel]}))
(assert (empty? (sessionless :stores))
        "sessions are off by default, so a fleet composition without them is clean")
(test/stop! sessionless)

(deploy/reset!)
(print "http deploy-test ok")
