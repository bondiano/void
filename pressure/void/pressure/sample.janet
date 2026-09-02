### void/pressure/sample — the meters (SPEC.md §5.23 and §8.4,
### ADR-0019).
###
### Two numbers, sampled on an interval, and both of them are about
### the same process, not the machine:
###
###   loop-lag  how much longer than it asked for a sleep took. On a
###             single-threaded ev-loop this is *the* saturation
###             signal (SPEC §8.4): the loop only runs late when
###             something else is running, so a lag of 200 ms means
###             every request in flight is already 200 ms behind, and
###             it says so before any latency percentile does.
###   rss       resident set size, read from the kernel — the number
###             the OOM killer and the container limit go by.
###
### **There is no heap meter, and that is a janet limit, not an
### omission.** ADR-0019 asked for one from "janet GC statistics";
### janet 1.41 has exactly three GC bindings — `gccollect`,
### `gcinterval`, `gcsetinterval` — and none of them reports how much
### is on the heap right now. RSS is the memory signal until janet
### grows one; a runtime that does know its own occupancy can say so
### through a `:void.pressure/check` contribution, which is what that
### extension point is for.
###
### RSS is read where the platform hands it over cheaply, and is nil
### where it does not — a signal with no meter is reported missing,
### never faked, and a threshold over a missing signal never trips:
###
###   linux   /proc/self/status, the VmRSS line. A file read, no ffi.
###   macos   task_info(mach_task_self(), MACH_TASK_BASIC_INFO) through
###           ffi/ — the current resident size, where getrusage's
###           ru_maxrss is a high-water mark that never comes back down
###           and so cannot drive a recovery.
###   other   nil.

(def lag-floor
  ``Sub-millisecond sleep drift that is the timer's, not the loop's.
  `ev/sleep` is scheduled against a poll timeout, so even an idle
  process wakes a little late; below this a sample reads as zero
  rather than as noise in the p99 of a health signal.``
  0.0005)

(defn lag
  ``One event-loop lag sample, in seconds: sleep `interval`, and
  return how much longer than `interval` the sleep actually took.
  Blocks the calling fiber for `interval` — this is the measurement,
  not a step before it.``
  [interval]
  (def before (os/clock :monotonic))
  (ev/sleep interval)
  (def drift (- (os/clock :monotonic) before interval))
  (if (< drift lag-floor) 0 drift))

# -- rss -----------------------------------------------------------------

(def- vmrss-line
  # `VmRSS:\t    5324 kB\n` — a tab, some spaces, the number, the unit
  # the kernel always writes for VmXXX, and the newline `file/read
  # :line` hands over. Matching the shape is the fix for a version of
  # this that sliced fixed offsets off both ends and so read `5324 k`
  # on every real /proc: `scan-number` said nil, the reader resolved to
  # "this platform has no RSS meter", and `[:pressure :max-rss-bytes]`
  # could not trip on Linux — which is to say, in every container.
  (peg/compile ~(* "VmRSS:" :s+ (number :d+) :s* "kB")))

(defn vmrss-bytes
  ``The resident set size on one line of `/proc/self/status`, in bytes,
  or nil when the line is not the VmRSS one. Public because it is the
  half of the Linux meter that can be tested anywhere.``
  [line]
  (when-let [[kb] (peg/match vmrss-line line)]
    (* 1024 kb)))

(defn- linux-rss []
  (when-let [f (file/open "/proc/self/status" :r)]
    (defer (file/close f)
      (var out nil)
      (loop [line :iterate (file/read f :line) :until out]
        (set out (vmrss-bytes line)))
      out)))

# MACH_TASK_BASIC_INFO and its count in 32-bit words: the flavor
# selects the struct below, and task_info wants its size in words the
# way every mach_msg-shaped call does.
(def- mach-task-basic-info 20)
(def- mach-task-basic-info-count 12)
# struct mach_task_basic_info: virtual_size, resident_size,
# resident_size_max (uint64 each), then the two time_value_t pairs and
# two ints — only the second field is wanted here.
(def- mach-resident-offset 8)

(defn- macos-rss-reader
  "A (fn [] bytes) over mach's task_info, or nil when the symbols are
  not where they are expected — an unusable meter reports itself
  missing rather than throwing once per sample."
  []
  (def [ok reader]
    (protect
      (let [lib (ffi/native "/usr/lib/libSystem.B.dylib")
            # mach_task_self_ is a data symbol (a mach_port_t), so the
            # pointer is read through, not called
            port (ffi/read :uint32 (ffi/pointer-buffer (ffi/lookup lib "mach_task_self_") 4 4 0))
            task-info (ffi/lookup lib "task_info")
            sig (ffi/signature :default :int :uint32 :uint32 :ptr :ptr)]
        (fn macos-rss []
          (def info (buffer/new-filled 64 0))
          (def count (buffer/new-filled 4 0))
          (ffi/write :uint32 mach-task-basic-info-count count 0)
          (when (zero? (ffi/call task-info sig port mach-task-basic-info info count))
            (int/to-number (ffi/read :uint64 info mach-resident-offset)))))))
  (when ok
    # a reader that cannot produce a number on its first call is not a
    # reader — the probe happens once, here, and never on the sampler's
    # own path
    (def [probed v] (protect (reader)))
    (when (and probed (number? v)) reader)))

(var- rss-reader :unresolved)

(defn reader
  "The RSS reader for this platform, or nil where there is none.
  Resolved once and remembered."
  []
  (when (= :unresolved rss-reader)
    (set rss-reader
         (case (os/which)
           :linux (let [[ok v] (protect (linux-rss))]
                    (if (and ok (number? v)) linux-rss nil))
           :macos (macos-rss-reader)
           nil)))
  rss-reader)

(defn rss
  "Resident set size in bytes, or nil where the platform has no cheap
  meter for it (see the module docstring)."
  []
  (when-let [r (reader)]
    (def [ok v] (protect (r)))
    (when (and ok (number? v)) v)))

(defn available
  "Which signals this process can actually measure — the health line
  that keeps a threshold over a missing meter from reading as a
  passing check."
  []
  {:loop-lag true
   :rss (not (nil? (reader)))
   # janet 1.41 exposes no heap occupancy; see the module docstring
   :heap false})
