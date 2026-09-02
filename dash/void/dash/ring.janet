### void/dash/ring — a fixed-memory ring buffer.
###
### The one data structure this package adds three times over: the log
### ring, the history samples and the tapped values are all "the last N
### things, and never more memory than N things take". Writes never
### allocate beyond the slot table; reads copy, so a page can render a
### snapshot while a sink keeps writing.

(defn make
  "A ring holding at most `capacity` entries."
  [capacity]
  (unless (and (int? capacity) (pos? capacity))
    (errorf "ring capacity must be a positive integer, got %q" capacity))
  @{:slots (array/new-filled capacity nil)
    :capacity capacity
    :next 0        # index the next write lands in
    :written 0})   # total writes ever, so readers can tell how much is real

(defn push!
  "Append one entry, evicting the oldest when full. Returns the ring."
  [ring entry]
  (put (ring :slots) (ring :next) entry)
  (put ring :next (mod (inc (ring :next)) (ring :capacity)))
  (put ring :written (inc (ring :written)))
  ring)

(defn to-array
  "The held entries, oldest first — a copy, safe to render while
  writes continue."
  [ring]
  (def n (min (ring :written) (ring :capacity)))
  (def start (if (< (ring :written) (ring :capacity))
               0
               (ring :next)))
  (def out (array/new n))
  (loop [i :range [0 n]]
    (array/push out (get (ring :slots) (mod (+ start i) (ring :capacity)))))
  out)

(defn size
  "How many entries the ring currently holds."
  [ring]
  (min (ring :written) (ring :capacity)))
