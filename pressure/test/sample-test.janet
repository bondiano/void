(import ../test-support/paths)
(import void/pressure/sample :as sample)

# -- loop-lag ------------------------------------------------------------

(def idle (sample/lag 0.02))
(assert (number? idle) "a sample is a number of seconds")
(assert (< idle 0.01)
        "an idle loop wakes on time — the signal is quiet when nothing is wrong")

# The measurement is the point: block the loop from another fiber and
# the sleeping fiber cannot be resumed until the block ends, which is
# exactly the thing loop-lag is for (a synchronous FFI call, a CPU
# loop, a GC pause — SPEC §8.4).
(ev/go
  (fn blocker []
    (ev/sleep 0.01)
    (def until (+ (os/clock :monotonic) 0.15))
    (while (< (os/clock :monotonic) until) (math/sqrt 2))))

(def blocked (sample/lag 0.02))
(assert (> blocked 0.05)
        (string/format "a blocked loop shows up as lag (got %.4f s)" blocked))

(assert (zero? (sample/lag 0.001))
        "drift under the timer's own resolution reads as zero, not as noise")

# -- what this platform can measure --------------------------------------

(def avail (sample/available))
(assert (avail :loop-lag) "loop-lag needs nothing but the loop")
(assert (not (avail :heap))
        "there is no heap meter — janet 1.41 has gccollect/gcinterval/gcsetinterval and no occupancy at all (see the module docstring)")

(def r (sample/rss))
(if (avail :rss)
  (do
    (assert (and (number? r) (pos? r))
            "where the platform has an RSS meter, it reports bytes")
    (assert (> r 1000000) "and a janet process is more than a megabyte")
    (assert (= (sample/reader) (sample/reader)) "the reader is resolved once"))
  (assert (nil? r)
          "and where it does not, the signal is nil — missing, never faked"))

(print "sample-test ok")
