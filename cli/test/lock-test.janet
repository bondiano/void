(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/deploy :as deploy)
(import void/cli/lock :as lock)
(import void/cli :as cli)

# The lock file exists so that "why is the middleware stack different in
# production" is a diff (void/cli/lock). Two things have to hold for
# that: the same composition has to produce the same bytes in two
# processes, and a different one has to produce a report that names
# what moved.

# -- the digest ----------------------------------------------------------

# published FNV-1a 64 vectors — the hash is a spelling, not an
# invention, and a wrong one would silently stop noticing changes
(assert (= "cbf29ce484222325" (lock/fnv1a "")) "the offset basis")
(assert (= "af63dc4c8601ec8c" (lock/fnv1a "a")) "one byte")
(assert (= "85944171f73967e8" (lock/fnv1a "foobar")) "six")

(assert (= (lock/digest {:a 1 :b 2}) (lock/digest {:b 2 :a 1}))
        "a dictionary hashes by its contents, not by its key order")
(assert (not= (lock/digest [1 2]) (lock/digest [2 1]))
        "a sequence hashes by its order — a reordered chain is a change")
(assert (not= (lock/digest {:a 1}) (lock/digest {:a 2})) "values count")

(defn named-fn [] 1)
(defn other-name [] 1)
(assert (= (lock/digest named-fn) (lock/digest named-fn))
        "a function hashes the same twice")
(assert (not= (lock/digest named-fn) (lock/digest other-name))
        "and differently from one with another name")
(assert (= (lock/digest (fn [] 1)) (lock/digest (fn [] 2)))
        "an anonymous function collapses to its anonymity — the honest
        boundary the file's header states")

(assert (string/find "#fn(named-fn)" (lock/canonical named-fn))
        "the canonical rendering names a function rather than addressing it")

# -- a composition -------------------------------------------------------

(defn- app-manifest [version extra-middleware]
  (plugin/manifest 'test/app
    :version version
    :components [(system/component :app/thing :start (fn [&] @{}))]
    :contributes
    {:void.http/middleware
     (if extra-middleware
       [{:name :app/one :phase 100 :fn (fn [h] h)}
        {:name :app/two :phase 200 :fn (fn [h] h)}]
       [{:name :app/one :phase 100 :fn (fn [h] h)}])}))

(defn- point-manifest []
  (plugin/manifest 'test/points
    :version "1.0.0"
    :extension-points
    {:void.http/middleware {:doc "middleware, for the suite"
                            :cardinality :many}}))

(defn- boot-of [& manifests]
  (deploy/reset!)
  (cli/bootstrap-app {:plugins (tuple ;manifests) :profile :test}))

(def base (lock/composition (boot-of (point-manifest) (app-manifest "1.0.0" false))))

(assert (= lock/lock-version (base :lock-version)) "the format version is recorded")
(assert (= :test (base :profile)) "and the profile, because a lock is per profile")
(assert (= :single (get-in base [:deploy :shape])) "and the deployment shape")

(assert (= (base :hash)
           ((lock/composition (boot-of (point-manifest) (app-manifest "1.0.0" false))) :hash))
        "the same composition, bootstrapped twice, hashes the same")

# -- the file round-trips ------------------------------------------------

(def root (os/cwd))
(def sandbox (string root "/.tmp-lock-test-" (os/time)))
(os/mkdir sandbox)
(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)
  (spit "void.lock" (lock/render base))
  (def read-back (lock/read-lock "void.lock"))
  (assert (= (base :hash) (read-back :hash)) "the file round-trips")
  (assert (deep= (base :points) (read-back :points))
          "including every point with its contribution chain")

  (assert (not (first (protect (lock/read-lock "nope.lock"))))
          "a missing lock file names the command that writes one")
  (spit "junk.lock" "not a lock file")
  (assert (not (first (protect (lock/read-lock "junk.lock"))))
          "and so does a file that is not one")
  (spit "old.lock" "{:lock-version 0}")
  (assert (not (first (protect (lock/read-lock "old.lock"))))
          "a lock-version this build does not write is a readable error"))

# -- the diff ------------------------------------------------------------

(assert (empty? (lock/diff base base)) "a composition does not differ from itself")

(def longer (lock/composition (boot-of (point-manifest) (app-manifest "1.0.0" true))))
(def added (lock/diff base longer))
(assert (some |(string/find ":void.http/middleware" $) added)
        "an added middleware is reported against its point")
(assert (some |(string/find "app/one -> test/app:app/two" $) added)
        "with the chain it is now part of")
(assert (some |(string/find "test/app" $) added)
        "and the plugin that declares it")

(def bumped (lock/composition (boot-of (point-manifest) (app-manifest "2.0.0" false))))
(assert (some |(string/find "1.0.0 -> 2.0.0" $) (lock/diff base bumped))
        "a version that moved is reported as a move")

(def without (lock/composition (boot-of (point-manifest))))
(assert (some |(string/find "is gone" $) (lock/diff base without))
        "a plugin that left is reported as gone")
(assert (some |(string/find "is new" $) (lock/diff without base))
        "and in the other direction, as new")

(def other-profile
  (do (deploy/reset!)
      (lock/composition
        (cli/bootstrap-app {:plugins [(point-manifest) (app-manifest "1.0.0" false)]}
                           :dev))))
(assert (some |(string/find "profile" $) (lock/diff base other-profile))
        "a lock taken in another profile says so, first")

(print "lock-test ok")
