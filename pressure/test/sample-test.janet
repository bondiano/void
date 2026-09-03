(import ../test-support/paths)
(import void/pressure/sample :as sample)

# -- loop-lag ------------------------------------------------------------

(def idle (sample/lag 0.02))
(assert (number? idle) "a sample is a number of seconds")
(assert (< idle 0.01)
        "an idle loop wakes on time — the signal is quiet when nothing is wrong")

# The measurement is the point: block the loop from another fiber and the
# sleeping fiber cannot be resumed until the block ends, which is exactly
# the thing loop-lag is for (a synchronous FFI call, a CPU loop, a GC
# pause).
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

# -- the Linux meter, on any platform ------------------------------------
#
# The parse is asserted here rather than through `sample/rss`, because
# `sample/rss` is nil on the machines where it is not Linux — which is
# exactly how a meter that read `5324 k` out of every real
# /proc/self/status shipped: the branch below asserted nil and was
# right to, and nobody was asserting the line.

(assert (= (* 1024 5324) (sample/vmrss-bytes "VmRSS:\t    5324 kB\n"))
        "the line as the kernel writes it — tab, padding, unit, and the newline file/read hands over")
(assert (= (* 1024 5324) (sample/vmrss-bytes "VmRSS:\t    5324 kB"))
        "and the same line without one")
(assert (nil? (sample/vmrss-bytes "VmHWM:\t    6000 kB\n"))
        "the high-water mark is a different line, and it never comes back down")
(assert (nil? (sample/vmrss-bytes "Name:\tjanet\n")))

(when (= :linux (os/which))
  (assert (avail :rss)
          "every Linux has /proc/self/status — a Linux that reports no RSS meter is a broken parse, not a platform"))

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
