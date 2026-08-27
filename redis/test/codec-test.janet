(import ../test-support/paths)
(import void/redis/codec :as codec)

# -- raw -----------------------------------------------------------------

(assert (= "hello" (codec/encode codec/raw "hello")))
(assert (= "42" (codec/encode codec/raw 42)) "a number goes as its text")
(assert (= "GET" (codec/encode codec/raw :GET)) "a keyword goes as its name")
(assert (= "hello" (codec/decode codec/raw "hello")) "and comes back the bytes redis holds")

# -- jdn -----------------------------------------------------------------

(each v [42 "text" :keyword {:a 1 :b [1 2 "three"]} @{:nested @{:deep true}} [1 2 3] 3.5]
  (assert (deep= v (codec/decode codec/jdn (codec/encode codec/jdn v)))
          (string/format "%q round-trips through jdn" v)))
(assert (= 1 ((codec/decode codec/jdn (codec/encode codec/jdn {:a 1})) :a))
        "a keyword key stays a keyword key — which is why sessions use jdn")

# -- json ----------------------------------------------------------------

(assert (deep= @{"a" 1} (codec/decode codec/json (codec/encode codec/json {:a 1})))
        "json comes back with string keys, which is the trade it makes")
(assert (= 42 (codec/decode codec/json (codec/encode codec/json 42))))

# -- absence -------------------------------------------------------------

(each c [codec/raw codec/jdn codec/json]
  (assert (nil? (codec/decode c nil))
          "a missing key is nil in every codec: absence is not a value to decode"))

(assert (deep= @[1 nil 2]
               (codec/decode-all codec/jdn @["1" nil "2"]))
        "and stays nil in the middle of a MGET")

# -- choosing ------------------------------------------------------------

(def registry (tabseq [c :in codec/builtin] (c :name) c))
(assert (= codec/jdn (codec/find-codec registry :jdn)))
(def [ok err] (protect (codec/find-codec registry :yaml)))
(assert (not ok) "a codec that was never contributed is an error")
(assert (and (string/find ":jdn" err) (string/find ":raw" err))
        "listing what there is, because this is usually a typo")

(printf "codec-test: ok")
