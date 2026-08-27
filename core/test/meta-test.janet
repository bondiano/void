(import ../void/core/meta :as meta)

# -- :concat over dictionaries (per-slot concat, ADR-0016) ---------------

(do
  (def decls (meta/declarations
               [(meta/declare-key :t/hooks :merge :concat)]))
  (def r (meta/merge-layers decls
                            [[:global {:t/hooks {:a [1] :b [2]}}]
                             [:route {:t/hooks {:a [3] :c [4]} :name :x}]]))
  (assert (empty? (r :errors)) (string/join (r :errors) ";"))
  (assert (= {:a [1 3] :b [2] :c [4]} (get-in r [:value :t/hooks]))
          "dictionary :concat concatenates per key")
  (def bad (meta/merge-layers decls
                              [[:global {:t/hooks [1]}]
                               [:route {:t/hooks {:a [2]} :name :x}]]))
  (assert (not (empty? (bad :errors))) "mixing shapes is an error"))

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- declarations --------------------------------------------------------

(expect-error "bare key declaration" "namespaced"
  |(meta/declare-key :policy))
(expect-error "unknown decl option" "unknown option"
  |(meta/declare-key :app/x :shema :int))
(expect-error "bad merge strategy" ":merge"
  |(meta/declare-key :app/x :merge :overwrite))
(expect-error ":restrict without :allow?" ":allow?"
  |(meta/declare-key :app/x :merge :restrict))
(expect-error "invalid decl schema" ":schema"
  |(meta/declare-key :app/x :schema [:wat]))

(def decls
  [(meta/declare-key :void.authz/policy
     :schema [:or :keyword [:vector :keyword]]
     :merge :replace)
   (meta/declare-key :void.http/middleware
     :schema [:vector :keyword]
     :merge :concat)
   (meta/declare-key :void.schema/params
     :merge :deep-merge)
   (meta/declare-key :void.http/timeout
     :schema :number
     :merge :restrict
     :allow? (fn [outer inner] (<= inner outer)))
   (meta/declare-key :void.security/csrf
     :schema :boolean
     :merge :restrict
     :allow? (fn [outer inner] (or inner (not outer))))])

(expect-error "duplicate declaration" "twice"
  |(meta/declarations [(meta/declare-key :app/x) (meta/declare-key :app/x)]))

# -- merge strategies ----------------------------------------------------

(def res
  (meta/merge-layers decls
    [[:global {:void.authz/policy :any
               :void.http/middleware [:audit]
               :void.schema/params {:headers {:x-req :string} :page :int}
               :void.http/timeout 30}]
     [:group {:void.authz/policy :admin
              :void.http/middleware [:admin-log]
              :void.schema/params {:headers {:x-tenant :string}}}]
     [:route {:name :users/list
              :void.http/timeout 5
              :void.http/middleware [:cache]}]]))

(assert (empty? (res :errors)) (string/format "unexpected errors: %q" (res :errors)))
(def v (res :value))
(assert (= :users/list (v :name)) ":name merges without declaration")
(assert (= :admin (v :void.authz/policy)) ":replace — the specific layer wins")
(assert (= [:audit :admin-log :cache] (v :void.http/middleware))
        ":concat — layers concatenate in order")
(assert (= 5 (v :void.http/timeout)) ":restrict allows tightening")
(assert (= {:x-req :string :x-tenant :string}
           (freeze (get-in v [:void.schema/params :headers])))
        ":deep-merge merges nested maps")
(assert (= :int (get-in v [:void.schema/params :page]))
        ":deep-merge keeps outer-only entries")

# provenance / explain
(def e (meta/explain res :void.http/timeout))
(assert (= 5 (e :value)))
(assert (= [:global :route] (freeze (map |($ :source) (e :history))))
        "provenance lists every contributing layer in order")
(assert (string/find ":route" (meta/explain-str res :void.http/timeout)))
(assert (string/find "not set" (meta/explain-str res :void.obs/name)))

# -- :restrict violations ------------------------------------------------

(def loosen
  (meta/merge-layers decls
    [{:void.http/timeout 5}
     {:void.http/timeout 30}]))
(assert (= 1 (length (loosen :errors))))
(assert (string/find "tighten" (first (loosen :errors))))
(assert (= 5 (get-in loosen [:value :void.http/timeout]))
        "the loosening layer does not win")

(def csrf-off
  (meta/merge-layers decls
    [{:void.security/csrf true}
     {:void.security/csrf false}]))
(assert (= 1 (length (csrf-off :errors))) "csrf cannot be switched off downstream")

(def csrf-on
  (meta/merge-layers decls
    [{:void.security/csrf false}
     {:void.security/csrf true}]))
(assert (empty? (csrf-on :errors)) "enabling csrf is a tightening")
(assert (get-in csrf-on [:value :void.security/csrf]))

(expect-error "merge-layers! throws the batch" "tighten"
  |(meta/merge-layers! decls [{:void.http/timeout 5} {:void.http/timeout 30}]))

# -- key validation ------------------------------------------------------

# typo -> did-you-mean
(def typo (meta/merge-layers decls [{:void.autz/policy :admin}]))
(assert (= 1 (length (typo :errors))))
(assert (string/find "did you mean" (first (typo :errors))))
(assert (string/find ":void.authz/policy" (first (typo :errors))))

# schema violation names the key and the layer
(def badval (meta/merge-layers decls [[:route {:void.http/middleware "cache"}]]))
(assert (= 1 (length (badval :errors))))
(assert (string/find ":void.http/middleware" (first (badval :errors))))
(assert (string/find ":route" (first (badval :errors))))

# bare keys: warning by default, error in :strict (CI) mode
(def bare (meta/merge-layers decls [{:timeout 5}]))
(assert (empty? (bare :errors)))
(assert (= 1 (length (bare :warnings))))
(assert (= 5 (get-in bare [:value :timeout])) "bare key still merges in dev")

(def bare-strict (meta/merge-layers decls [{:timeout 5}] {:strict true}))
(assert (= 1 (length (bare-strict :errors))) "bare key is an error in :strict")

# multiple errors are collected, not first-fail
(def multi (meta/merge-layers decls
             [{:void.autz/policy :x
               :void.http/middleware "nope"
               :void.http/timeout "soon"}]))
(assert (= 3 (length (multi :errors))) "all errors collected in one pass")

# declarations also accept a dictionary form
(def dict-res
  (meta/merge-layers {:app/flag {:schema :boolean}}
    [{:app/flag true}]))
(assert (empty? (dict-res :errors)))
(assert (get-in dict-res [:value :app/flag]))

(print "meta-test: all assertions passed")
