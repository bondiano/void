(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/schema :as schema)
(import void/dev :as dev)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat)))

# -- the manifest passes dry-run and carries its :source -----------------

(def report (plugin/dry-run {:plugins [:void/dev]}))
(assert (= [:void/dev] (report :active)))
(assert (= [:dev/netrepl :dev/watcher] (freeze (sorted (report :components)))))
(assert (= 1 (get-in report [:extensions :void.core/schema-projection :contributions]))
        "the :generator projection is contributed")
(assert (string/has-suffix? "init.janet" (get dev/manifest :source))
        "defplugin recorded the defining file")

# -- config schema catches bad config ------------------------------------

(expect-error "bad :dev config" "void/dev"
  |(plugin/dry-run {:plugins [:void/dev]
                    :config {:cli {:dev {:watch {:interval "fast"}}}}}))

# -- full cycle: start with a short socket path, use, stop ---------------

(def sock (string "./.void-dev-" (os/time) ".sock"))
(def boot
  (plugin/start!
    {:plugins [:void/dev]
     :config {:cli {:dev {:netrepl {:unix sock}
                          :watch {:enabled false}}}}}))
(assert (= :ready (boot :phase)))
(assert (= :socket (os/stat sock :mode)) "netrepl came up from plugin config")
(assert (= {:disabled true} (system/instance (boot :system) :dev/watcher))
        "watcher honors :enabled false")
(assert (schema/valid? :int (schema/project :generator :int))
        "the contributed projection is usable")
(plugin/shutdown! boot)
(assert (nil? (os/stat sock)) "socket removed on shutdown")

# -- exit criterion: removing the plugin leaves no trace -----------------

(def bare (plugin/dry-run {:plugins []}))
(assert (= [] (bare :active)))
(assert (= [] (bare :components)))

(print "dev-plugin-test: all assertions passed")
