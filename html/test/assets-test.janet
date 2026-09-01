(import ../test-support/paths)
(import spork/sh)
(import void/html/assets :as assets)

# -- fingerprint ---------------------------------------------------------

(assert (= "app-0d4a1185.css" (assets/fingerprint "app.css" "hello world")))
(assert (= "css/app.min-0d4a1185.css"
           (assets/fingerprint "css/app.min.css" "hello world"))
        "the hash lands before the last extension")
(assert (= "LICENSE-0d4a1185" (assets/fingerprint "LICENSE" "hello world")))
(assert (not= (assets/fingerprint "a.css" "one") (assets/fingerprint "a.css" "two"))
        "content changes change the name")

# -- build! + manifest ---------------------------------------------------

(def tmp "test/tmp-assets")
(sh/rm tmp)
(os/mkdir "test")
(os/mkdir tmp)
(os/mkdir (string tmp "/src"))
(os/mkdir (string tmp "/src/css"))
(spit (string tmp "/src/css/app.css") "body { color: red }")
(spit (string tmp "/src/htmx.js") "window.htmx = {}")

(def manifest (assets/build! {:root (string tmp "/src")
                              :out (string tmp "/out")}))

(assert (= 2 (length manifest)))
(def css-target (manifest "css/app.css"))
(assert (string/has-prefix? "css/app-" css-target))
(assert (string/has-suffix? ".css" css-target))
(assert (= "body { color: red }"
           (string (slurp (string tmp "/out/" css-target))))
        "content is copied verbatim under the fingerprinted name")

# -- steps run before the walk -------------------------------------------

(def order @[])
(def stepped
  (assets/build! {:root (string tmp "/src")
                  :out (string tmp "/stepped")
                  :steps [(fn [] (array/push order :first)
                            (spit (string tmp "/src/generated.css") "a{}"))
                          (fn [] (array/push order :second))]}))
(assert (= [:first :second] (tuple ;order)) "steps run in order")
(assert (get stepped "generated.css")
        "what a step wrote into :root is fingerprinted like the rest")
(os/rm (string tmp "/src/generated.css"))

(def loaded (assets/load-manifest (string tmp "/out/manifest.jdn")))
(assert (deep= (freeze manifest) (freeze loaded))
        "the manifest round-trips through its file")

# -- href ----------------------------------------------------------------

(assert (= (string "/assets/" css-target)
           (assets/href loaded "/assets/" "css/app.css")))
(assert (= "/assets/css/app.css" (assets/href nil "/assets/" "css/app.css"))
        "no manifest -> dev passthrough")
(assert (not (first (protect (assets/href loaded "/assets/" "missing.css"))))
        "a missing manifest entry is an error, not a fallback")
(assert (not (first (protect (assets/load-manifest "test/nope.jdn")))))

(sh/rm tmp)
(print "assets-test: ok")
