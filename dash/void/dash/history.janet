### void/dash/history — fixed-memory time series for the sparklines.
###
### Everything the audit found introspectable is an instant snapshot;
### nothing in the composition keeps yesterday. This module keeps a
### bounded slice of it: one ring of samples ({:ts :lag-ms :rss
### :connections}), written by a sampler fiber the :dash/state
### component runs, sized by [:dash :history] and never growing past
### it.
###
### The loop lag is measured here, not read from void/obs: an ev/sleep
### that comes back late came back late by exactly the lag of the loop,
### and measuring it costs one clock read — so the sparkline works in a
### composition with no observability plugin at all. RSS and the open
### connections *are* read from the composition (through the component
### health seam ./pages resolves), and stay nil — a gap in the line,
### not a zero — when their components are absent.

(import ./ring :as ring)

(def default-interval "Seconds between samples." 5)
(def default-samples "Ring capacity — half an hour at the default interval." 360)

(var samples
  "The ring of {:ts :lag-ms :rss :connections} samples."
  (ring/make default-samples))

(defn configure!
  "Size the ring from the [:dash :history] slice — called at
  :before-start. Same capacity keeps the ring; a change is a fresh
  one."
  [cfg]
  (def cap (get cfg :samples default-samples))
  (unless (= cap (samples :capacity))
    (set samples (ring/make cap)))
  samples)

(defn held
  "How many samples the ring holds."
  []
  (ring/size samples))

(defn record!
  "Append one sample."
  [s]
  (ring/push! samples s))

(defn series
  "One field of every held sample, oldest first (nils kept — a gap in
  a sparkline is information)."
  [k]
  (map |(get $ k) (ring/to-array samples)))

(defn last-sample
  "The newest sample, or nil."
  []
  (last (ring/to-array samples)))

(def- slice
  "The longest single sleep the sampler takes, so a stop is honored
  within a slice rather than an interval — a shutdown must not wait
  five seconds for a sparkline."
  0.1)

(defn sampler
  ``The sampler as a fiber body: every `interval` seconds measure the
  loop lag accumulated around its own sleeps, ask `sources` (a
  function of no arguments answering {:rss :connections} or nil-valued
  fields) and push one sample. Runs until `running` (a table) has
  :stop set — checked every `slice` seconds, so the :dash/state
  component's :stop never cancels a fiber and never waits.``
  [interval sources running &opt on-sample]
  (fn dash-sampler []
    (while (not (running :stop))
      (var drift 0)
      (var left interval)
      (while (and (pos? left) (not (running :stop)))
        (def dt (min slice left))
        (def before (os/clock :monotonic))
        (ev/sleep dt)
        (+= drift (max 0 (- (os/clock :monotonic) before dt)))
        (-= left dt))
      (when (running :stop) (break))
      (def src (or (when sources
                     (let [[ok v] (protect (sources))] (when ok v)))
                   {}))
      (record! {:ts (os/clock :realtime)
                :lag-ms (* 1000 drift)
                :rss (get src :rss)
                :connections (get src :connections)})
      (when on-sample (protect (on-sample))))))
