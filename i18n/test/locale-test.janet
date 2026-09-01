(import ../test-support/paths)
(import void/i18n/locale :as locale)

# -- normalize -----------------------------------------------------------

(assert (= :ru (locale/normalize "ru")))
(assert (= :ru-ru (locale/normalize "ru-RU")))
(assert (= :ru-ru (locale/normalize "ru_RU")))
(assert (= :ru-ru (locale/normalize :ru-RU)))
(assert (= :en (locale/normalize :en)))
(assert (nil? (locale/normalize nil)))
(assert (nil? (locale/normalize "")))
(assert (nil? (locale/normalize "not a tag")) "spaces are refused")
(assert (nil? (locale/normalize "../etc")) "a header value is visitor input")
(assert (nil? (locale/normalize "-en")) "a tag starts with a subtag")
(assert (nil? (locale/normalize "en-")) "and ends with one")

(assert (= :en (locale/primary :en-us)))
(assert (= :ru (locale/primary :ru)))

# -- Accept-Language parsing ---------------------------------------------

(def entries (locale/parse-accept-language "da, en-GB;q=0.8, en;q=0.7"))
(assert (deep= @["da" "en-gb" "en"] (map |($ :tag) entries)) "sorted by q, lowercased")
(assert (= 0.8 ((entries 1) :q)))

(assert (= [] (locale/parse-accept-language nil)) "no header means no preference")
(assert (= [] (locale/parse-accept-language "")))
(assert (= [] (locale/parse-accept-language ";;;")) "an unparseable header means no preference")

(def wild (locale/parse-accept-language "*;q=0.9, fr;q=0.9"))
(assert (= "fr" ((first wild) :tag)) "a wildcard loses a tie against a real tag")

# -- negotiation ---------------------------------------------------------

(assert (= :ru (locale/negotiate "ru" [:en :ru])))
(assert (= :ru (locale/negotiate "ru-RU" [:en :ru])) "ru-RU matches the primary")
(assert (= :en-us (locale/negotiate "en" [:ru :en-us])) "en matches the regional variant")
(assert (= :en (locale/negotiate "de, en;q=0.5" [:en :ru])) "the preferred tag is unavailable, the next is taken")
(assert (= :en (locale/negotiate "*" [:en :ru])) "a wildcard takes the first configured locale")
(assert (nil? (locale/negotiate "de" [:en :ru])) "nothing matches — the caller falls to the default")
(assert (nil? (locale/negotiate nil [:en :ru])))
(assert (nil? (locale/negotiate "ru;q=0" [:en :ru])) "q=0 excludes a tag")
(assert (= :en (locale/negotiate "ru;q=0.9, en" [:en :ru])) "q beats header order — an unweighted tag is q=1")
(assert (= :ru (locale/negotiate "en;q=0.3, ru;q=0.9" [:en :ru])))

(print "locale-test: ok")
