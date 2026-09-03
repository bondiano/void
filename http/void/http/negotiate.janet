### void/http/negotiate — content negotiation.
###
### Accept-header parsing and best-match selection over the media types
### a handler offers. Pure functions; the parsing middleware and
### void/rest are the consumers. Matching follows RFC 9110 §12.5.1:
### quality weights, then specificity (type/sub over type/* over */*);
### q=0 excludes a type entirely.

(def- accept-peg
  (peg/compile
    ~{:ows (any (set " \t"))
      :token '(some (if-not (set ",;= \t") 1))
      :param (* :ows ";" :ows :token :ows "=" :ows :token)
      :entry (* :ows :token (group (any :param)) :ows)
      :main (* :entry (any (* "," :entry)) -1)}))

(def- qvalue-peg
  # RFC 9110 §12.4.2: 0[.000-999] or 1[.000] and nothing else —
  # scan-number's hex/exponent leniency has no place in a weight
  (peg/compile '(* (+ (* "1" (? (* "." (between 0 3 "0"))))
                      (* "0" (? (* "." (between 0 3 :d)))))
                   -1)))

(defn- split-media [s]
  (if-let [i (string/find "/" s)]
    [(string/ascii-lower (string/slice s 0 i))
     (string/ascii-lower (string/slice s (inc i)))]
    [(string/ascii-lower s) "*"]))

(defn parse-accept
  ``Parse an Accept header into entries sorted by preference:
  [{:type "text" :sub "html" :q 1 :specificity 2} ...]. nil or an
  unparseable header means "anything" ([{:type "*" :sub "*" :q 1}]).``
  [s]
  (if (or (nil? s) (empty? (string/trim (string s))))
    [{:type "*" :sub "*" :q 1 :specificity 0}]
    (if-let [m (peg/match accept-peg s)]
      (do
        (def entries @[])
        (loop [i :range [0 (length m) 2]]
          (def [t sub] (split-media (m i)))
          (var q 1)
          (def params (m (inc i)))
          (loop [j :range [0 (length params) 2]]
            (when (= "q" (string/ascii-lower (params j)))
              (def v (params (inc j)))
              (set q (if (peg/match qvalue-peg v) (scan-number v) 1))))
          (array/push entries
                      {:type t :sub sub :q q
                       :specificity (cond (= "*" t) 0 (= "*" sub) 1 2)}))
        (sorted-by (fn [e] [(- (e :q)) (- (e :specificity))]) entries))
      [{:type "*" :sub "*" :q 1 :specificity 0}])))

(defn- entry-matches? [entry [t sub]]
  (and (or (= "*" (entry :type)) (= t (entry :type)))
       (or (= "*" (entry :sub)) (= sub (entry :sub)))))

(defn- match-q
  "The q of the most specific Accept entry matching a media type
  (RFC 9110: text/html;q=1 beats text/*;q=0 for text/html), or nil
  when nothing matches."
  [entries media]
  (var best-e nil)
  (each e entries
    (when (and (entry-matches? e media)
               (or (nil? best-e) (> (e :specificity) (best-e :specificity))))
      (set best-e e)))
  (when best-e (best-e :q)))

(defn accepts?
  "Would this Accept header take the given media type?"
  [accept-header mime]
  (def q (match-q (parse-accept accept-header) (split-media mime)))
  (and q (> q 0) true))

(defn best
  ``The best of the offered media types for an Accept header, or nil
  when none is acceptable:

      (negotiate/best "text/html,application/json;q=0.9"
                      ["application/json" "text/html"])   # "text/html"

  Offers are full types ("application/json"); ties go to the offer
  listed first.``
  [accept-header offers]
  (def entries (parse-accept accept-header))
  (var best-offer nil)
  (var best-q 0)
  (loop [i :range [0 (length offers)]]
    (def offer (offers i))
    (def q (match-q entries (split-media offer)))
    (when (and q (> q best-q))
      (set best-q q)
      (set best-offer offer)))
  best-offer)

(defn negotiate
  "best over a request table — reads the accept header."
  [req offers]
  (def accept (get-in req [:headers "accept"]))
  (best (if (indexed? accept) (first accept) accept) offers))
