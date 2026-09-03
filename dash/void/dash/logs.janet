### void/dash/logs — the one real gap the audit named, closed with a
### ring (M2).
###
### `log/emit` fans a record out to the sinks and forgets it; every
### sink so far writes somewhere else. This one keeps the last
### [:dash :log-buffer] records in a ring — bounded by construction —
### and hands them to two readers: the Logs page (last records, level
### and namespace filters, htmx poll) and a live tail over SSE, one
### line per record, whose subscription is released by the same
### cancellation chain the datastar streams stand on (ring/sse forwards
### the server's cancel into the producer, so the `defer` here runs).
###
### The one *action* in the whole dashboard also lives here: runtime
### per-namespace log levels, which `log/set-level!` has answered since
### wave 0. It is guarded separately — `[:dash :allow-actions]` — and
### the change is itself logged, because an operator flipping a
### namespace to :trace is exactly the line the next operator wants to
### find in the tail.

(import void/core/log :as log)
(import void/http/ring :as httpring)
(import void/html/init :as html)
(import void/htmx/init :as htmx)
(import ./context :as ctx)
(import ./live :as live)
(import ./ring :as ring)
(import ./view :as view)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.dash")

(def default-capacity "Records held when [:dash :log-buffer] says nothing." 500)

(var records
  "The ring of log records, exactly as `log/emit` assembled them."
  (ring/make default-capacity))

(def subscribers
  "Live tails: conn table -> true. Module-level like the ring, so a
  kernel-only boot can tail too; the :dash/state component closes
  every channel at stop so a drain ends the streams."
  @{})

(defn configure!
  "Size the ring from [:dash :log-buffer] — called at :before-start.
  A ring of the same capacity is kept as it is (a restart must not
  wipe the record of why it restarted); a changed capacity is a fresh
  ring."
  [capacity]
  (def cap (or capacity default-capacity))
  (unless (= cap (records :capacity))
    (set records (ring/make cap)))
  records)

(defn held
  "How many records the ring holds."
  []
  (ring/size records))

(defn sink
  ``The :void.core/log-sink contribution: keep the record, wake the
  tails, poke the live page. Never throws and never blocks — a full
  tail drops the record for that tail (the page re-syncs on its next
  poll), which is the jdn-sink's own posture.``
  [rec]
  (ring/push! records rec)
  (eachk conn subscribers
    (def ch (conn :chan))
    (when (< (ev/count ch) (ev/capacity ch))
      (ev/give ch rec)))
  (live/poke! live/logs-room)
  nil)

(defn close-subscribers!
  "Close every tail's channel — its taker wakes with nil and the
  stream fiber unsubscribes itself. The :dash/state component calls
  this at :stop."
  []
  (eachk conn subscribers
    (ev/chan-close (conn :chan)))
  nil)

# -- rendering -----------------------------------------------------------

(def- skip-keys {:ts true :level true :ns true :msg true})

(defn record-line
  "One record as one line — the pretty sink's shape, uncolored."
  [rec]
  (def d (os/date (math/floor (get rec :ts 0)) true))
  (def kvs
    (string/join
      (seq [k :in (sorted (filter |(not (in skip-keys $)) (keys rec)))]
        (string/format "%s=%s" (string k) (view/value-str (rec k) 120)))
      " "))
  (string/format "%02d:%02d:%02d %-5s %s — %s%s"
                 (d :hours) (d :minutes) (d :seconds)
                 (string/ascii-upper (string (get rec :level :info)))
                 (string (get rec :ns "?"))
                 (string (get rec :msg ""))
                 (if (empty? kvs) "" (string " " kvs))))

# -- the page ------------------------------------------------------------

(def- level-rank {:trace 10 :debug 20 :info 30 :warn 40 :error 50 :fatal 60})

(defn- listing-state [req]
  (def lvl (let [v (get-in req [:query "level"])]
             (when (and (string? v) (in level-rank (keyword v))) (keyword v))))
  (def ns* (let [v (get-in req [:query "ns"])]
             (when (and (string? v) (not (empty? v))) v)))
  {:level lvl :ns ns*})

(defn- matching [st]
  (def min-rank (get level-rank (st :level) 0))
  (filter (fn [rec]
            (and (>= (get level-rank (get rec :level) 30) min-rank)
                 (or (nil? (st :ns))
                     (string/find (st :ns) (string (get rec :ns ""))))))
          (ring/to-array records)))

(defn- filter-panel [st]
  [:form {:method "get" :action (ctx/at "/logs") :class "dash-toolbar"
          :hx-get (ctx/at "/logs")
          :hx-target "#dash-logs"
          :hx-swap "outerHTML"
          :hx-push-url "true"
          :hx-trigger "change, submit"}
   [:div {:class "field"}
    [:label {:for "f-level"} "Level ≥"]
    [:select {:name "level" :id "f-level"}
     [:option {:value ""} "any"]
     ;(seq [l :in [:trace :debug :info :warn :error :fatal]]
        [:option {:value (string l) :selected (when (= l (st :level)) true)}
         (string l)])]]
   [:div {:class "field"}
    [:label {:for "f-ns"} "Namespace contains"]
    [:input {:type "search" :name "ns" :id "f-ns" :value (st :ns)}]]
   [:div {:class "field"} [:button {:type "submit"} "Filter"]]])

(defn- csrf-slot []
  (when-let [f (dyn :void.html/csrf)] (f)))

(defn- level-form []
  (def allowed (ctx/setting :allow-actions?))
  [:div
   [:h2 "Log levels"]
   (if allowed
     [:form {:method "post" :action (ctx/at "/logs/level") :class "dash-toolbar"}
      (csrf-slot)
      [:div {:class "field"}
       [:label {:for "a-ns"} "Namespace (empty = root)"]
       [:input {:type "text" :name "ns" :id "a-ns" :placeholder "my-app.orders"}]]
      [:div {:class "field"}
       [:label {:for "a-level"} "Level"]
       [:select {:name "level" :id "a-level"}
        ;(seq [l :in [:trace :debug :info :warn :error :fatal]]
           [:option {:value (string l) :selected (when (= :info l) true)} (string l)])]]
      [:div {:class "field"} [:button {:type "submit"} "Set"]]]
     [:p {:class "dash-absent"}
      "Changing levels is off: [:dash :allow-actions] is not true in this profile — the pages stay read-only until the config says otherwise."])])

(defn- params [st]
  @{"level" (st :level) "ns" (st :ns)})

(defn logs-fragment
  "The moving half: the matching records, newest last, capped for the
  page (the ring holds more than a page should)."
  [st]
  (def all (matching st))
  (def shown (if (> (length all) 200) (array/slice all -201) all))
  [:div {:id "dash-logs"
         :hx-get (ctx/at "/logs" (params st))
         :hx-trigger "every 5s"
         :hx-swap "outerHTML"}
   [:p {:class "dash-note"}
    (string (length shown) " of " (ring/size records) " held record"
            (if (= 1 (ring/size records)) "" "s")
            " (ring of " (records :capacity) ") · live tail: ")
    [:a {:href (ctx/at "/logs/tail")} "SSE stream"]
    (string " · dropped by async sinks: " (log/dropped))]
   (if (empty? shown)
     [:p {:class "dash-empty"} "No record matches."]
     [:pre {:class "dash-jdn dash-logs"}
      ;(seq [rec :in shown]
         [:span {:class (string "dash-log-" (string (get rec :level :info)))}
          (string (record-line rec) "\n")])])])

(defn logs-body [st]
  [:div (view/live-attrs "/logs/live")
   [:h1 "Logs"]
   (filter-panel st)
   (logs-fragment st)
   (level-form)])

(defn index [req]
  (def st (listing-state req))
  (if (htmx/partial-request? req)
    (html/fragment (logs-fragment st))
    (html/page (logs-body st) {:layout view/layout :context {:request req}})))

# -- the live tail -------------------------------------------------------

(defn tail
  ``The SSE tail: every record from now on, one `data:` line each. The
  subscription is registered on connect and released by the `defer`
  when the consumer goes away — the server cancels the body fiber,
  ring/sse forwards the cancel into this coro, and the defer runs
  (the A8 chain, asserted by this package's own suite).``
  [_req]
  (def conn @{:chan (ev/chan 64)})
  (httpring/sse
    (coro
      (put subscribers conn true)
      (defer (put subscribers conn nil)
        (yield {:event "hello" :data "void/dash log tail"})
        (forever
          (def rec (ev/take (conn :chan)))
          (when (nil? rec) (break))       # close-subscribers! at stop
          (yield {:event "log" :data (record-line rec)}))))))

# -- the action ----------------------------------------------------------

(defn set-level
  "POST /logs/level — runtime per-namespace levels, behind
  [:dash :allow-actions]."
  [req]
  (unless (ctx/setting :allow-actions?)
    (break @{:status 403
             :headers @{"content-type" "text/plain; charset=utf-8"}
             :body "the dash is read-only: set [:dash :allow-actions] true to allow runtime log-level changes."}))
  (def ns* (let [v (get-in req [:form "ns"])]
             (when (and (string? v) (not (empty? (string/trim v))))
               (string/trim v))))
  (def lvl (keyword (get-in req [:form "level"] "")))
  (unless (in level-rank lvl)
    (break @{:status 422
             :headers @{"content-type" "text/plain; charset=utf-8"}
             :body (string "unknown level " (string lvl)
                           " (levels: trace debug info warn error fatal)")}))
  (log/set-level! ns* lvl)
  (log/info "log level set from the dash" :ns log-ns
            :target (or ns* "<root>") :level lvl)
  @{:status 303 :headers @{"location" (ctx/at "/logs")}})
