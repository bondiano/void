(import ../test-support/paths)
(import void/cache/key :as key)

# -- keys written by hand are used as written ----------------------------

(assert (= "rates:usd" (key/cache-key "rates:usd")))
(assert (= "rates" (key/cache-key :rates)) "a keyword is its name, colon dropped")
(assert (= "rates" (key/cache-key @"rates")) "and a buffer is its bytes")
(assert (= "42" (key/cache-key 42)) "a number is the number, not a rendering of one")
(assert (= (key/cache-key 42) (key/cache-key "42"))
        "which makes them one key — the answer anybody would want from a cache")
(assert (= "[k4:user#42;]" (key/cache-key [:user 42]))
        "a composite key is canonical, and unambiguous")

# -- keys derived from values are deterministic and injective ------------

(assert (= (key/canonical {:a 1 :b 2}) (key/canonical {:b 2 :a 1}))
        "dictionary order is not part of the value, so it is not part of the key")
(assert (= (key/canonical {:a 1 :b 2}) (key/canonical @{:b 2 :a 1}))
        "and neither is table-ness")
(assert (= (key/canonical [1 2 3]) (key/canonical @[1 2 3])))
(assert (not= (key/canonical [1 2]) (key/canonical [2 1]))
        "but order inside a sequence is")

(each [a b] [[1 "1"] [:a "a"] ['a :a] ["ab" ["a" "b"]] [nil false] [nil "n"]
             [{:a 1} [:a 1]] [[[1]] [1]]]
  (assert (not= (key/canonical a) (key/canonical b))
          (string/format "%q and %q are different values and get different keys" a b)))

(assert (= (key/canonical 1) (key/canonical 1.0))
        "1 and 1.0 are the same Janet number, so they are the same key")

(each v [print (fiber/new (fn [] 1))]
  (def [ok err] (protect (key/canonical v)))
  (assert (not ok) "a value with no data-level identity cannot be a key")
  (assert (string/find "cache key" err) "and the error says so"))

# -- call keys -----------------------------------------------------------

(assert (= (key/for-call :rates ["usd" 2]) (key/for-call "rates" ["usd" 2]))
        "the name is a name however it is spelled")
(assert (not= (key/for-call :rates ["usd"]) (key/for-call :rates ["eur"])))
(assert (not= (key/for-call :rates []) (key/for-call :rates [nil]))
        "no arguments and one nil argument are different calls")
(assert (string/has-prefix? "rates" (key/for-call :rates ["usd"]))
        "and the key starts with the name, so a keyspace stays readable")

(printf "key-test: ok")
