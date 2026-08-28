# The text exposition: name mangling, label escaping, integers that
# stay integers, cumulative histogram buckets, and a declared metric
# that has not fired still being announced.

(import ../test-support/paths)
(import void/obs/metrics :as metrics)
(import void/obs/prometheus :as prom)

(metrics/clear-registry!)

# -- names and numbers ---------------------------------------------------

(assert (= "void_http_requests_total" (prom/metric-name :void.http/requests-total))
        "dots, slashes and dashes all become underscores — the plugin that owns the metric stays visible in the exported name")
(assert (= "_9lives" (prom/metric-name :9lives)) "a name may not start with a digit")

(assert (= "12345678901" (prom/number-str 12345678901))
        "a counter past 2^32 must not come out in scientific notation")
(assert (= "0.5" (prom/number-str 0.5)))
(assert (= "NaN" (prom/number-str "not a number")))

# -- a counter with labels ----------------------------------------------

(def requests (metrics/counter :void.http/requests-total
                {:doc "HTTP requests" :labels [:route :method :status]}))
(metrics/inc! requests ["orders.show" "get" "200"] 42)

(def text (prom/render (metrics/snapshot)))
(assert (string/find "# HELP void_http_requests_total HTTP requests" text))
(assert (string/find "# TYPE void_http_requests_total counter" text))
(assert (string/find `void_http_requests_total{route="orders.show",method="get",status="200"} 42` text)
        "one line per series, labels in declared order")

# -- escaping ------------------------------------------------------------

(def odd (metrics/counter :test/odd {:labels [:name]}))
(metrics/inc! odd [`a "quote" and a \backslash`])
(def odd-text (prom/render (metrics/snapshot)))
(assert (string/find `\"quote\"` odd-text) "quotes are escaped")
(assert (string/find `\\backslash` odd-text) "and so are backslashes")

# -- histograms ----------------------------------------------------------

(metrics/clear-registry!)
(def dur (metrics/histogram :test/duration-seconds
           {:doc "d" :labels [:route] :buckets [0.01 0.1 1]}))
(each v [0.005 0.05 0.5 5] (metrics/observe! dur ["home"] v))
(def h (prom/render (metrics/snapshot)))
(assert (string/find "# TYPE test_duration_seconds histogram" h))
(assert (string/find `test_duration_seconds_bucket{route="home",le="0.01"} 1` h))
(assert (string/find `test_duration_seconds_bucket{route="home",le="0.1"} 2` h)
        "buckets are cumulative — le means less than or equal, so each includes the ones before it")
(assert (string/find `test_duration_seconds_bucket{route="home",le="1"} 3` h))
(assert (string/find `test_duration_seconds_bucket{route="home",le="+Inf"} 4` h)
        "and +Inf is the count, which is what makes the 5 s observation visible at all")
(assert (string/find `test_duration_seconds_count{route="home"} 4` h))
(assert (string/find `test_duration_seconds_sum{route="home"} 5.555` h))

# -- a metric that has not fired ----------------------------------------

(metrics/clear-registry!)
(metrics/counter :test/never {:doc "never fired"})
(def n (prom/render (metrics/snapshot)))
(assert (string/find "# TYPE test_never counter" n)
        "a declared metric with no series is still announced: a scraper sees a metric that has not fired, not a metric that vanished")
(assert (not (string/find "\ntest_never " n)) "and no value line under it")

(metrics/clear-registry!)
(print "prometheus-test ok")
