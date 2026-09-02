### The ring, the sampler and the sparklines (M3, the memory half).
###
### Claims. The ring is fixed memory: capacity entries, the oldest
### evicted, reads are copies. The sampler measures the loop lag around
### its own sleeps (no void/obs needed), reads its optional sources
### through a function, survives a throwing source, and stops by flag
### within a slice. A sparkline is inline SVG over the series, nils are
### gaps not zeros, and one number is not a line. And the overview of a
### started system draws them from the :dash/state component's samples.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/system :as system)
(import void/test :as test)
(import void/dash/ring :as ring)
(import void/dash/history :as history)
(import void/dash/view :as view)

(log/set-level! nil :error)

# -- the ring ------------------------------------------------------------

(def r (ring/make 3))
(assert (= 0 (ring/size r)))
(each x [1 2 3 4 5] (ring/push! r x))
(assert (= 3 (ring/size r)) "capacity is the whole of the memory")
(assert (deep= @[3 4 5] (ring/to-array r)) "oldest first, oldest evicted")
(assert (= 5 (r :written)) "the ring still knows how much passed through")
(assert (not (first (protect (ring/make 0)))) "a zero ring is refused")

# -- the sampler ---------------------------------------------------------

(history/configure! {:samples 50})
(var source-calls 0)
(def running @{})
(def fib
  (ev/go (history/sampler 0.02
                          (fn [] (++ source-calls)
                            (if (= 2 source-calls)
                              (error "the source hiccuped")
                              {:rss 1000 :connections 2}))
                          running)))
(ev/sleep 0.2)
(put running :stop true)
(ev/sleep 0.15)
(assert (not= :pending (fiber/status fib)) "the sampler stopped by flag, uncancelled")
(assert (>= (history/held) 3) (string "samples were taken: " (history/held)))
(assert (all number? (history/series :lag-ms)) "lag is measured, every tick")
(assert (some nil? (history/series :rss))
        "a throwing source is a gap in the line, not a dead sampler")
(assert (some |(= 1000 $) (history/series :rss)) "and a working one is a number")

# eviction keeps it fixed
(history/configure! {:samples 5})
(loop [_ :range [0 10]] (history/record! {:ts 0 :lag-ms 1}))
(assert (= 5 (history/held)) "history never outgrows [:dash :history :samples]")

# -- sparklines ----------------------------------------------------------

(assert (nil? (view/sparkline [])) "no data, no line")
(assert (nil? (view/sparkline [3])) "one number is not a line")
(assert (nil? (view/sparkline [nil nil])) "gaps alone are not a line")
(def svg (view/sparkline [1 nil 2 3]))
(assert (= :svg (first svg)) "inline SVG, no JavaScript")
(assert (string/find "polyline" (string/format "%j" svg)))

(def flat (view/sparkline [2 2 2]))
(assert flat "a flat line is still a line, not a division by zero")

# -- the overview draws them ---------------------------------------------

(def boot
  (test/start! {:plugins ["void/http/init" "void/html/init" "void/htmx/init" "void/dash/init"]
                :profile :dev
                :config {:env @{} :cli {:http {:port 0}
                                        :dash {:history {:interval 0.05 :samples 10}}}}
                :only [:http/kernel :dash/state]}))
(defer (test/stop! boot)
  (ev/sleep 0.2)
  (def c (test/client boot))
  (def page (test/text (test/inject c {:uri "/dash"})))
  (assert (string/find "<svg" page)
          "the overview carries a sparkline once the sampler has enough")
  (assert (string/find "own samples" page)
          "and says whose numbers they are")
  (def st (system/instance (boot :system) :dash/state))
  (assert st "the state component runs")
  (assert (pos? (history/held)) "and it sampled"))

(print "history-test: ok")
