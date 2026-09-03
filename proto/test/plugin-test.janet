(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/proto :as proto)
(import void/proto/descriptor :as desc)
(require "void/proto/init")

# -- the manifest holds together on its own ------------------------------

(def boot (plugin/dry-run {:plugins [:void/proto] :profile :test}))
(assert boot "void/proto dry-runs alone — it needs no transport and no components")
(assert (empty? (get-in boot [:system :components] {}))
        "and starts nothing: a codec has no lifecycle")

# the two custom schema types and the :proto projection are declared
# through the core points, so plugin/inspect and CONTRACTS.md show them
(assert (= 2 (get-in boot [:extensions :void.core/schema-type :contributions]))
        "the 64-bit integer types are declared, not smuggled in")
(assert (= 1 (get-in boot [:extensions :void.core/schema-projection :contributions]))
        "and the :proto projection is the row reserved for it")
(assert (index-of :proto/int64 (schema/types)))
(assert (index-of :proto/uint64 (schema/types)))
(assert (index-of :proto (schema/projections)))
(assert (get-in boot [:extensions :void.proto/file])
        "and the package declares its own point for the .proto files a plugin ships")

(def full (plugin/bootstrap {:plugins [:void/proto] :profile :test} true))
(def commands (get-in full [:extensions :void.core/cli :resolved] []))
(def by-name (tabseq [c :in commands] (c :name) c))
(assert (by-name :proto/list))
(assert (by-name :proto/describe))
(each c [(by-name :proto/list) (by-name :proto/describe)]
  (assert (c :read-only?)
          "both commands are read-only, so an agent may run them"))

# -- the config slice ----------------------------------------------------

(assert (deep= [] (get-in full [:config :values :proto :paths])))
(def [ok _] (protect (plugin/dry-run {:plugins [:void/proto] :profile :test
                                      :config {:cli {:proto {:paths "not a list"}}}})))
(assert (not ok) "a [:proto :paths] that is not a list of strings fails the bootstrap")

# -- .proto files a plugin ships -----------------------------------------

(plugin/register-manifest!
  (plugin/manifest 'test/proto-consumer
    :version "0.0.1"
    :requires {:void/proto ">=0.0.1"}
    :contributes {:void.proto/file [{:name :test/orders
                                     :path "test/protos/orders.proto"}]}))

(def with-file (plugin/bootstrap {:plugins [:void/proto :test/proto-consumer] :profile :test} true))
(def contributed (get-in with-file [:extensions :void.proto/file :resolved] []))
(assert (= 1 (length contributed)))
(assert (= "test/protos/orders.proto" ((first contributed) :path)))

# dry-run stops before :before-start, so nothing has been loaded yet —
# the hook is what loads it, and running it is what a started system does
(desc/deregister! :shop.orders/Order)
(assert (nil? (desc/lookup :shop.orders/Order)))
(each h (get-in with-file [:extensions :void.core/hooks :resolved] [])
  (when (= :proto/load-files (h :name)) ((h :fn) with-file)))
(assert (desc/lookup :shop.orders/Order)
        "the :before-start hook loaded the file the plugin named")
(assert (schema/lookup :shop.orders/Order)
        "and the schema layer saw it, because it watches the registry")

# a path that is not there fails the boot, naming the plugin
(plugin/register-manifest!
  (plugin/manifest 'test/proto-missing
    :version "0.0.1"
    :requires {:void/proto ">=0.0.1"}
    :contributes {:void.proto/file [{:name :test/nope :path "test/protos/nope.proto"}]}))
(def missing (plugin/bootstrap {:plugins [:void/proto :test/proto-missing] :profile :test} true))
(def hook (first (filter |(= :proto/load-files ($ :name))
                         (get-in missing [:extensions :void.core/hooks :resolved] []))))
(def [ok err] (protect ((hook :fn) missing)))
(assert (not ok))
(assert (string/find "test/nope" err) "and the error says which contribution and which file")

# -- the CLI commands print what they promise ----------------------------

(proto/defmessage :cli/Thing {:a [1 :string]})

(defn- captured [f]
  (def out @"")
  (with-dyns [:out out] (f))
  (string out))

(def listed (captured |((get-in by-name [:proto/list :fn]))))
(assert (string/find "cli.Thing" listed) "void proto list shows a registered message")
(assert (string/find "message" listed))
(def services (captured |((get-in by-name [:proto/list :fn]) "services")))
(assert (not (string/find "cli.Thing" services)) "and filters by kind when asked")

(def described (captured |((get-in by-name [:proto/describe :fn]) "cli.Thing")))
(assert (string/find "message Thing" described))
(assert (string/find "string a = 1;" described)
        "void proto describe prints .proto source, which is what the descriptor means")

(assert (not (first (protect ((get-in by-name [:proto/describe :fn]) "nothing.At.All")))))
(assert (not (first (protect ((get-in by-name [:proto/list :fn]) "everything")))))

# -- removing the plugin leaves no trace ---------------------------------

(def without (plugin/bootstrap {:plugins [] :profile :test} true))
(assert (empty? (get-in without [:extensions :void.core/cli :resolved] []))
        "no void/proto, no proto commands (Definition of Done, point 1)")

(print "plugin ok")
