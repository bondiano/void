### void/core/semver — versions and the constraints they satisfy.
###
### Owns the one notion of "version" the plugin API has: "1.2.3" read
### into a [major minor patch] tuple, and the constraint language a
### manifest's :requires speaks — ">=0.1 <0.5", "^1.2", "~1.2", an
### exact "1.2.3". It is its own module because two readers need it
### that otherwise share nothing: the manifest checks that a
### constraint parses when the plugin is defined, and boot phase 1
### asks whether the version actually loaded satisfies it. Neither
### should have to pull in the other to answer. No imports: this sits
### under everything else in the plugin API.

(defn parse-version
  "Parse \"1.2.3\" (also \"v1.2\", \"0.1\", prerelease tail ignored)
  into a [major minor patch] tuple; missing parts default to 0."
  [s]
  (unless (string? s)
    (errorf "version must be a string, got %q" s))
  (def src (if (string/has-prefix? "v" s) (string/slice s 1) s))
  (def parts (string/split "." (first (string/split "-" src))))
  (when (or (empty? parts) (> (length parts) 3))
    (errorf "cannot parse version %q" s))
  (def nums
    (map (fn [p]
           (def n (scan-number p))
           (unless (and n (>= n 0) (= n (math/trunc n)))
             (errorf "cannot parse version %q" s))
           n)
         parts))
  [(get nums 0 0) (get nums 1 0) (get nums 2 0)])

(defn- vcmp
  "Compare two parsed versions the way `cmp` does: -1, 0 or 1 by the
  first of major, minor, patch that differs."
  [a b]
  (var r 0)
  (loop [i :range [0 3] :while (zero? r)]
    (set r (cmp (a i) (b i))))
  r)

(defn- caret-upper
  "The exclusive upper bound of a caret range: the next major when the
  major is non-zero, else the next minor, else the next patch — the
  npm reading of `^`, where a 0.x release may break on every minor."
  [v]
  (cond
    (pos? (v 0)) [(inc (v 0)) 0 0]
    (pos? (v 1)) [0 (inc (v 1)) 0]
    [0 0 (inc (v 2))]))

(defn parse-constraint
  "Parse one comparator token of a constraint string — \">=1.2\",
  \"^1\", \"~0.3\", \"1.2.3\" — into `[op version]`, where `op` is one
  of :>= :<= :> :< := :caret :tilde. Throws on an unparsable version,
  which is how a manifest's :requires is checked at definition time."
  [tok]
  (def [op rest]
    (cond
      (string/has-prefix? ">=" tok) [:>= (string/slice tok 2)]
      (string/has-prefix? "<=" tok) [:<= (string/slice tok 2)]
      (string/has-prefix? ">" tok) [:> (string/slice tok 1)]
      (string/has-prefix? "<" tok) [:< (string/slice tok 1)]
      (string/has-prefix? "=" tok) [:= (string/slice tok 1)]
      (string/has-prefix? "^" tok) [:caret (string/slice tok 1)]
      (string/has-prefix? "~" tok) [:tilde (string/slice tok 1)]
      [:= tok]))
  [op (parse-version rest)])

(defn satisfies?
  ``True when a version satisfies a constraint string: space-separated
  comparators, all of which must hold — ">=0.1 <0.5", "^1.2" (same
  major, or same minor while major is 0), "~1.2" (same minor),
  "1.2.3" (exact).``
  [version constraint]
  (def v (if (string? version) (parse-version version) version))
  (all (fn [tok]
         (def [op c] (parse-constraint tok))
         (case op
           :>= (>= (vcmp v c) 0)
           :<= (<= (vcmp v c) 0)
           :> (> (vcmp v c) 0)
           :< (< (vcmp v c) 0)
           := (zero? (vcmp v c))
           :caret (and (>= (vcmp v c) 0) (neg? (vcmp v (caret-upper c))))
           :tilde (and (>= (vcmp v c) 0)
                       (neg? (vcmp v [(c 0) (inc (c 1)) 0])))))
       (filter |(not (empty? $)) (string/split " " constraint))))
