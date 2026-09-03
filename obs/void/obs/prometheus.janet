### void/obs/prometheus — the text exposition format.
###
### A pure projection of `metrics/snapshot`: data in, one string out,
### no state and no I/O. That is what makes it testable without a
### server and what made the OTLP exporter (./otlp) a *second*
### projection of the same snapshot rather than a second metric model —
### same values, same names, same units.
###
### The format is the 0.0.4 text exposition every Prometheus-compatible
### scraper reads (and the one `promtool check metrics` validates):
###
###     # HELP void_http_requests_total HTTP requests
###     # TYPE void_http_requests_total counter
###     void_http_requests_total{route="orders.show",method="get",status="200"} 42
###
### Two conversions happen here and nowhere else, so the rest of void
### can keep speaking Janet:
###
###   names   `:void.http/requests-total` -> `void_http_requests_total`.
###           Namespaced keywords are how a metric says which plugin
###           owns it; dots, slashes and dashes are not legal in a
###           Prometheus name, and mapping all three to `_` keeps the
###           ownership visible in the exported name.
###   units   seconds and bytes, always — Prometheus base units. void
###           measures in seconds everywhere a duration crosses this
###           module (the pools count microseconds internally and are
###           converted at collection), so nothing here divides by a
###           thousand and no dashboard has to guess.
###
### Histograms are exported cumulatively (`le` buckets are "less than
### or equal", so each bucket includes the ones before it) plus `_sum`
### and `_count`, which is what a `histogram_quantile()` needs.

(def content-type
  "What a /metrics response says it is."
  "text/plain; version=0.0.4; charset=utf-8")

(defn metric-name
  ``A metric keyword as a Prometheus name: `:void.http/requests-total`
  -> `void_http_requests_total`.``
  [name]
  (def s (string name))
  (def out (buffer/new (length s)))
  (each c s
    (buffer/push-byte out
      (if (or (and (>= c 97) (<= c 122))     # a-z
              (and (>= c 65) (<= c 90))      # A-Z
              (and (>= c 48) (<= c 57))      # 0-9
              (= c 58))                      # :
        c
        (chr "_"))))
  (def str (string out))
  # a name may not start with a digit
  (if (and (not (empty? str)) (>= (str 0) 48) (<= (str 0) 57))
    (string "_" str)
    str))

(defn- escape-label [v]
  (def s (string v))
  (def out (buffer/new (length s)))
  (each c s
    (case c
      (chr "\\") (buffer/push-string out "\\\\")
      (chr "\"") (buffer/push-string out "\\\"")
      (chr "\n") (buffer/push-string out "\\n")
      (buffer/push-byte out c)))
  (string out))

(defn number-str
  ``A number as the exposition wants it: integers plainly (a counter of
  12345678901 must not come out as 1.23457e+10) and everything else at
  twelve significant digits, which is past any resolution a duration
  histogram carries.``
  [n]
  (cond
    (not (number? n)) "NaN"
    (and (= n (math/floor n)) (< (math/abs n) 9007199254740992))
    (string/format "%d" n)
    (string/format "%.12g" n)))

(defn- labels-str [names values &opt extra]
  (def parts @[])
  (var i 0)
  (each name names
    (array/push parts (string/format "%s=\"%s\"" (metric-name name)
                                     (escape-label (get values i ""))))
    (++ i))
  (each [k v] (or extra [])
    (array/push parts (string/format "%s=\"%s\"" k (escape-label v))))
  (if (empty? parts) "" (string "{" (string/join parts ",") "}")))

(defn- render-metric [out m]
  (def name (metric-name (m :name)))
  (def series (m :series))
  (when (not (empty? (m :doc)))
    (buffer/format out "# HELP %s %s\n" name
                   (string/replace-all "\n" " " (m :doc))))
  (buffer/format out "# TYPE %s %s\n" name (string (m :kind)))
  (if (= :histogram (m :kind))
    (each s series
      (def base (labels-str (m :labels) (s :labels)))
      (var acc 0)
      (var i 0)
      (each bound (m :buckets)
        (+= acc (get-in s [:buckets i] 0))
        (buffer/format out "%s_bucket%s %s\n" name
                       (labels-str (m :labels) (s :labels)
                                   [["le" (number-str bound)]])
                       (number-str acc))
        (++ i))
      (buffer/format out "%s_bucket%s %s\n" name
                     (labels-str (m :labels) (s :labels) [["le" "+Inf"]])
                     (number-str (s :count)))
      (buffer/format out "%s_sum%s %s\n" name base (number-str (s :sum)))
      (buffer/format out "%s_count%s %s\n" name base (number-str (s :count))))
    (each s series
      (buffer/format out "%s%s %s\n" name
                     (labels-str (m :labels) (s :labels))
                     (number-str (s :value)))))
  out)

(defn render
  ``A `metrics/snapshot` as one exposition string. Metrics with no
  series at all are still announced (HELP/TYPE), so a scraper sees a
  metric that exists and has not fired rather than a metric that
  vanished.``
  [snapshot]
  (def out (buffer/new 4096))
  (each m snapshot (render-metric out m))
  (string out))
