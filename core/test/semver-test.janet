(import ../void/core/semver :as semver)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string name ": message " (string/format "%q" err) " lacks " (string/format "%q" pat)))
  err)

# -- parse-constraint: the token grammar a manifest's :requires is checked with

(assert (= [:>= [1 2 0]] (semver/parse-constraint ">=1.2")))
(assert (= [:<= [1 2 3]] (semver/parse-constraint "<=1.2.3")))
(assert (= [:> [0 1 0]] (semver/parse-constraint ">0.1")))
(assert (= [:< [2 0 0]] (semver/parse-constraint "<2")))
(assert (= [:= [1 0 0]] (semver/parse-constraint "=1")) "an explicit =")
(assert (= [:= [1 0 0]] (semver/parse-constraint "1")) "a bare version is exact")
(assert (= [:caret [1 2 0]] (semver/parse-constraint "^1.2")))
(assert (= [:tilde [0 3 1]] (semver/parse-constraint "~0.3.1")))
(assert (= [:>= [1 2 3]] (semver/parse-constraint ">=v1.2.3-rc1")) "v prefix and prerelease tail as in parse-version")
(expect-error "garbage after the operator" "cannot parse version" |(semver/parse-constraint ">=x"))
(expect-error "an empty token" "cannot parse version" |(semver/parse-constraint ""))

# -- the parse feeds satisfies?: every operator behaves as its token says

(assert (semver/satisfies? "1.2.0" ">=1.2"))
(assert (not (semver/satisfies? "1.1.9" ">=1.2")))
(assert (semver/satisfies? "1.2.3" "<=1.2.3"))
(assert (not (semver/satisfies? "1.2.4" "<=1.2.3")))
(assert (semver/satisfies? "0.1.1" ">0.1"))
(assert (not (semver/satisfies? "0.1.0" ">0.1")))
(assert (semver/satisfies? "1.9.9" "<2"))
(assert (not (semver/satisfies? "2.0.0" "<2")))
(assert (semver/satisfies? "1.0.0" "=1"))
(assert (not (semver/satisfies? "1.0.1" "=1")))
(assert (semver/satisfies? [1 5 0] "^1.2") "a parsed tuple is accepted as the version")
(assert (not (semver/satisfies? "2.0.0" "^1.2")) "caret stops at the next major")
(assert (semver/satisfies? "0.3.9" "^0.3") "a 0.x caret stays within the minor")
(assert (not (semver/satisfies? "0.4.0" "^0.3")))
(assert (semver/satisfies? "0.0.5" "^0.0.5") "a 0.0.x caret is that patch alone")
(assert (not (semver/satisfies? "0.0.6" "^0.0.5")))
(assert (semver/satisfies? "0.3.9" "~0.3.1"))
(assert (not (semver/satisfies? "0.4.0" "~0.3.1")))
(assert (semver/satisfies? "1.3.0" ">=1.2  <1.4") "several comparators, extra spaces ignored")
(assert (not (semver/satisfies? "1.4.0" ">=1.2 <1.4")))

(print "semver-test: all assertions passed")
