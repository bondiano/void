(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/cache :as cache)
(import void/cache/state :as state)

(log/set-level! "void.cache" :error)

(def plugins ["void/cache/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own")
(assert (index-of :cache/memory (report :components)) "the memory store is in the graph")
(assert (index-of :cache/store (report :components)) "and the cache over it")

(def interfaces (get-in report [:extensions :void.core/interface :contributions]))
(assert (and interfaces (>= interfaces 2))
        "both interfaces are declared — the one you depend on and the one you implement")

(each [slice reason]
  [[{:cache {:ttl -1}} "a negative ttl"]
   [{:cache {:memory {:max-entries 0}}} "a cache that can hold nothing"]
   [{:cache {:on-error :explode}} "an error policy nobody implements"]
   [{:cache {:prefix :not-a-string}} "a prefix that is not a string"]]
  (def [ok err] (protect (plugin/dry-run {:plugins plugins :profile :test
                                          :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

(def [tok] (protect (plugin/dry-run {:plugins plugins :profile :test
                                     :config (config {:cache {:ttl :none}})})))
(assert tok ":none is a ttl like any other")

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:cache {:prefix "t:" :ttl 30
                                                   :memory {:max-entries 4
                                                            :sweep-interval 0}}})}))
(defer (plugin/shutdown! boot 3)
  (def c (get-in boot [:system :instances :cache/store]))
  (assert c "the cache component started")
  (assert (= "t:" (c :prefix)) "with the configured prefix")
  (assert (= 30 (c :ttl)))
  (assert (= :memory (get-in c [:store :name])) "over the store this plugin ships")
  (assert (= c (state/active-cache)) "and it is what the module-level functions reach for")

  # -- the surface applications import ------------------------------------

  (cache/put! "answer" {:value 42})
  (assert (= 42 ((cache/get "answer") :value)))
  (assert (cache/has? "answer"))
  (assert (deep= [true {:value 42}] (cache/fetch "answer")))
  (assert (= :fresh (cache/remember "other" 10 (fn [] :fresh))))
  (assert (= :fresh (cache/remember "other" 10 (fn [] :recomputed))))

  (def rates (cache/wrap (fn rates [c] {:c c})))
  (assert (deep= {:c "usd"} (rates "usd")))

  (assert (cache/delete! "answer"))
  (assert (pos? (cache/clear!)))

  # the LRU cap from the config is the store's cap
  (each i (range 20) (cache/put! (string "k" i) i))
  (assert (= 4 (get (cache/stats) :entries)) "the configured cap holds")

  # -- health -------------------------------------------------------------

  (def h ((system/health (boot :system)) :components))
  (assert (= :up (get-in h [:cache/store :status])))
  (assert (= :memory (get-in h [:cache/store :store])))
  (assert (number? (get-in h [:cache/store :hit-rate])))
  (assert (= :up (get-in h [:cache/memory :status])))
  (assert (= 4 (get-in h [:cache/memory :entries])))

  # -- the CLI commands ---------------------------------------------------

  (def cli (get-in boot [:extensions :void.core/cli :resolved]))
  (def names (map |($ :name) cli))
  (each n [:cache/stats :cache/get :cache/forget :cache/clear]
    (assert (index-of n names) (string/format "%q is contributed" n)))
  (each entry cli
    (when (index-of (entry :name) [:cache/stats :cache/get :cache/forget :cache/clear])
      (assert (deep= [:cache/store] (entry :needs))
              "and asks for the cache component, so `void cache ...` starts nothing else")))

  # and they run — the surface they print through is the one that
  # shadows `get`, which is a compile-order question worth a test
  (defn- command [name] (find |(= name ($ :name)) cli))
  (cache/put! "shown" 1)
  (each [name args] [[:cache/stats []] [:cache/get ["shown"]] [:cache/get ["missing"]]
                     [:cache/forget ["shown"]] [:cache/forget ["shown"]] [:cache/clear []]]
    (def [ok err] (protect (with-dyns [:out @""] (((command name) :fn) c ;args))))
    (assert ok (string/format "%q %j runs: %q" name args err)))
  (each [name args] [[:cache/stats ["extra"]] [:cache/get []] [:cache/clear ["extra"]]]
    (def [ok] (protect (with-dyns [:out @""] (((command name) :fn) c ;args))))
    (assert (not ok) (string/format "%q %j is a usage error, not a surprise" name args))))

# -- the plugin leaves no trace when it is not there ---------------------

(def bare (plugin/dry-run {:plugins [] :profile :test :config (config {})}))
(assert (empty? (filter |(string/has-prefix? "cache" (string $)) (bare :components)))
        "drop it from :plugins and no component of it remains")

# -- the cache is gone with the plugin -----------------------------------

(assert (nil? state/current-cache) "shutdown leaves no cache behind")
(def [gone] (protect (cache/get "answer")))
(assert (not gone) "and the surface says so instead of pretending")

(printf "plugin-test: ok")
