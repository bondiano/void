(import ../test-support/paths)
(import void/bench/wrk :as wrk)

# -- unit conversion -----------------------------------------------------

(assert (= 0.634 (wrk/to-ms 634 "us")) "us -> ms")
(assert (= 1.23 (wrk/to-ms 1.23 "ms")) "ms stays")
(assert (= 1500 (wrk/to-ms 1.5 "s")) "s -> ms")
(assert (= 60000 (wrk/to-ms 1 "m")) "m -> ms")

# -- parsing wrk (max throughput) output ---------------------------------

(def wrk-output
  ```
Running 5s test @ http://127.0.0.1:8100/
  4 threads and 64 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   634.00us    1.15ms  25.10ms   91.23%
    Req/Sec    21.50k     2.10k   26.00k    68.00%
  Latency Distribution
     50%  634.00us
     75%    1.15ms
     90%    1.85ms
     99%    3.90ms
  428000 requests in 5.00s, 52.30MB read
Requests/sec:  85434.72
Transfer/sec:     10.46MB
```)

(def parsed (wrk/parse wrk-output))
(assert (= 85434.72 (parsed :rps)) "Requests/sec parsed")
(assert (= 0.634 (get-in parsed [:latency :p50])) "p50 in us -> ms")
(assert (= 1.15 (get-in parsed [:latency :p75])) "p75")
(assert (= 3.9 (get-in parsed [:latency :p99])) "p99")
(assert (nil? (parsed :non-2xx)) "no error lines -> no counters")

# -- parsing wrk2 (fixed rate) output ------------------------------------

(def wrk2-output
  ```
Running 1m test @ http://127.0.0.1:8100/
  4 threads and 64 connections
  Thread calibration: mean lat.: 1.201ms, rate sampling interval: 10ms
  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%    1.23ms
 75.000%    1.79ms
 90.000%    2.34ms
 99.000%    4.87ms
 99.900%   12.20ms
 99.990%   25.00ms
100.000%   31.90ms

  Detailed Percentile spectrum:
       Value   Percentile   TotalCount 1/(1-Percentile)
       0.401     0.000000            1         1.00
       1.230     0.500000       480312         2.00
      31.903     1.000000       960001          inf
  960001 requests in 1.00m, 117.30MB read
  Non-2xx or 3xx responses: 12
  Socket errors: connect 0, read 3, write 0, timeout 1
Requests/sec:  15998.11
Transfer/sec:      1.95MB
```)

(def parsed2 (wrk/parse wrk2-output))
(assert (= 15998.11 (parsed2 :rps)) "wrk2 Requests/sec parsed")
(assert (= 1.23 (get-in parsed2 [:latency :p50])) "wrk2 p50")
(assert (= 4.87 (get-in parsed2 [:latency :p99])) "wrk2 p99")
(assert (= 12.2 (get-in parsed2 [:latency :p999])) "wrk2 p99.9")
(assert (nil? (get-in parsed2 [:latency :p100]))
        "untracked percentiles and the detailed spectrum are ignored")
(assert (= 12 (parsed2 :non-2xx)) "non-2xx counter")
(assert (= 4 (parsed2 :socket-errors)) "socket errors summed")

# -- median / summarize --------------------------------------------------

(assert (nil? (wrk/median [])) "median of nothing is nil")
(assert (= 2 (wrk/median [3 1 2])) "odd median")
(assert (= 2.5 (wrk/median [4 1 2 3])) "even median is the middle mean")

(def summary
  (wrk/summarize
    [@{:rps 100 :latency @{:p50 1 :p99 5} :non-2xx 1}
     @{:rps 300 :latency @{:p50 3 :p99 4}}
     @{:rps 200 :latency @{:p50 2 :p99 6}}]))
(assert (= 200 (summary :rps)) "rps median across runs")
(assert (= 2 (summary :p50)) "p50 median across runs")
(assert (= 5 (summary :p99)) "p99 median across runs")
(assert (= 1 (summary :non-2xx)) "error counters summed")
(assert (nil? (summary :socket-errors)) "zero counters omitted")
(assert (nil? (summary :p999)) "unreported metrics omitted")

# -- command building ----------------------------------------------------

(assert (deep= (wrk/tool-argv "wrk") @["wrk"]) "plain tool name")
(assert (deep= (wrk/tool-argv "taskset -c 0 wrk") @["taskset" "-c" "0" "wrk"])
        "multi-word override splits into an argv prefix")

(assert (deep= (wrk/command {:tool "wrk" :url "http://x/" :threads 4
                             :connections 64 :duration 60})
               ["wrk" "-t" "4" "-c" "64" "-d" "60s" "--latency" "http://x/"])
        "wrk command without rate/script")

(assert (deep= (wrk/command {:tool "wrk2" :url "http://x/echo" :threads 4
                             :connections 64 :duration 60 :rate 6400
                             :script "/b/post.lua"})
               ["wrk2" "-t" "4" "-c" "64" "-d" "60s" "--latency"
                "-R" "6400" "-s" "/b/post.lua" "http://x/echo"])
        "wrk2 command with rate and script")

(print "wrk-test ok")
