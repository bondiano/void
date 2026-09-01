### void/i18n/locale — locale tags and Accept-Language (ADR-0036).
###
### Pure functions. A locale is a lowercase keyword (:en, :ru, :en-us);
### `normalize` folds whatever a header, a cookie or a hook produced
### into that shape and refuses anything else — both are written by the
### visitor. `negotiate` picks the best configured locale for an
### Accept-Language value: RFC 4647 basic filtering (exact tag, then
### primary language either way), quality weights first, q=0 excluded.
### The shape of the parser is void/http/negotiate's, which stops at
### media types — type/sub does not fit a language tag.

(def- tag-peg
  # a normalized tag: language and optional subtags, nothing a header
  # writer could smuggle further down
  (peg/compile '(* (between 1 8 (range "az" "09")) (any (* "-" (between 1 8 (range "az" "09")))) -1)))

(defn normalize
  ``A locale as a lowercase keyword: "ru_RU", "ru-RU", :RU -> :ru-ru;
  nil, empty or anything but subtags of [a-z0-9] -> nil.``
  [x]
  (when x
    (def s (string/ascii-lower (string/replace-all "_" "-" (string x))))
    (when (peg/match tag-peg s)
      (keyword s))))

(defn primary
  "The primary language of a locale: :en-us -> :en."
  [loc]
  (def s (string loc))
  (if-let [i (string/find "-" s)]
    (keyword (string/slice s 0 i))
    loc))

(def- accept-peg
  (peg/compile
    ~{:ows (any (set " \t"))
      :tag '(some (+ (range "az" "AZ" "09") (set "-_*")))
      :param (* :ows ";" :ows '(some (if-not (set ",;= \t") 1)) :ows "=" :ows '(some (if-not (set ",; \t") 1)))
      :entry (* :ows :tag (group (any :param)) :ows)
      :main (* :entry (any (* "," :entry)) -1)}))

(defn parse-accept-language
  ``Parse an Accept-Language header into entries sorted by preference:
  [{:tag "en-us" :q 1} ...]. Tags are lowercased; nil or an
  unparseable header means "no preference" ([]).``
  [s]
  (if (or (nil? s) (empty? (string/trim (string s))))
    []
    (if-let [m (peg/match accept-peg s)]
      (do
        (def entries @[])
        (loop [i :range [0 (length m) 2]]
          (def tag (string/ascii-lower (string/replace-all "_" "-" (m i))))
          (var q 1)
          (def params (m (inc i)))
          (loop [j :range [0 (length params) 2]]
            (when (= "q" (string/ascii-lower (params j)))
              (set q (or (scan-number (params (inc j))) 1))))
          (array/push entries {:tag tag :q q}))
        # q first; a wildcard loses every tie; the header's own order
        # breaks the rest (sorted-by is stable)
        (sorted-by (fn [e] [(- (e :q)) (if (= "*" (e :tag)) 1 0)]) entries))
      [])))

(defn negotiate
  ``The best of `available` (normalized locale keywords) for an
  Accept-Language value, or nil when nothing matches: exact tag, then
  "en-us" against :en, then "en" against :en-us, in preference order.``
  [header available]
  (def avail (filter |(not (nil? $)) (map normalize available)))
  (var found nil)
  (each e (parse-accept-language header)
    (when (and (nil? found) (> (e :q) 0))
      (def tag (e :tag))
      (set found
           (if (= "*" tag)
             (first avail)
             (when-let [k (normalize tag)]
               (def p (primary k))
               (or (find |(= $ k) avail)
                   (find |(= $ p) avail)
                   (find |(= (primary $) p) avail)))))))
  found)
