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
(import void/core/keys :as keys)
(import void/http/ring :as httpring)
(import void/html/init :as html)
(import void/htmx/hx :as hx)
(import ./context :as ctx)
(import ./text :as text)
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
  {:params [:number?] :ret @{:slots @[:any] :capacity :number :next :number :written :number}
   :throws [:string]}
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
  {:params [] :ret :number}
  "How many records the ring holds."
  []
  (ring/size records))

(defn sink
  {:params [@{:ts :number :level :keyword :ns :string :msg :any & r}] :ret :nil :throws [:string]}
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
  {:params [] :ret :nil}
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
  {:params [{:ts :number :level :keyword :ns :string :msg :any & r}] :ret :string}
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

(defn- listing-state
  {:params [{:query {:string :any} & r}] :ret {:level :keyword? :ns :string?}}
  "The level floor and namespace substring a request's query asks to
  filter by, or nothing (any level, every namespace)."
  [req]
  (def lvl (let [v (get-in req [:query "level"])]
             (when (and (string? v) (in level-rank (keyword v))) (keyword v))))
  (def ns* (let [v (get-in req [:query "ns"])]
             (when (and (string? v) (not (empty? v))) v)))
  {:level lvl :ns ns*})

(defn- matching
  {:params [{:level :keyword? :ns :string?}] :ret @[:any]}
  "The held records passing `st`'s level floor and namespace substring."
  [st]
  (def min-rank (get level-rank (st :level) 0))
  (filter (fn [rec]
            (and (>= (get level-rank (get rec :level) 30) min-rank)
                 (or (nil? (st :ns))
                     (string/find (st :ns) (string (get rec :ns ""))))))
          (ring/to-array records)))

(defn- filter-panel
  {:params [{:level :keyword? :ns :string?}] :ret :any :throws [:string]}
  "The level/namespace filter form, as hiccup."
  [st]
  [:form (merge {:method "get" :action (ctx/at "/logs") :class "vd-toolbar"}
                (hx/get* (ctx/at "/logs") :target "#dash-logs" :swap :outer-html :push-url true
                         :trigger "change, submit"))
   [:div {:class "field"}
    [:label {:for "f-level"} (text/t :void.dash/level-at-least)]
    [:select {:name "level" :id "f-level"}
     [:option {:value ""} (text/t :void.dash/any)]
     ;(seq [l :in [:trace :debug :info :warn :error :fatal]]
        [:option {:value (string l) :selected (when (= l (st :level)) true)}
         (string l)])]]
   [:div {:class "field"}
    [:label {:for "f-ns"} (text/t :void.dash/namespace-contains)]
    [:input {:type "search" :name "ns" :id "f-ns" :value (st :ns)}]]
   [:div {:class "field"} [:button {:type "submit"} (text/t :void.dash/filter)]]])

(defn- csrf-slot
  {:params [] :ret :any}
  "The hidden CSRF field the form middleware bound, or nothing when
  it is not in this composition."
  []
  (when-let [f (dyn keys/csrf-field)] (f)))

(defn- level-form
  {:params [] :ret :any :throws [:string]}
  "The runtime log-level form, or the sentence saying actions are off."
  []
  (def allowed (ctx/setting :allow-actions?))
  [:div
   [:h2 (text/t :void.dash/log-levels)]
   (if allowed
     [:form {:method "post" :action (ctx/at "/logs/level") :class "vd-toolbar"}
      (csrf-slot)
      [:div {:class "field"}
       [:label {:for "a-ns"} (text/t :void.dash/namespace-root)]
       [:input {:type "text" :name "ns" :id "a-ns" :placeholder "my-app.orders"}]]
      [:div {:class "field"}
       [:label {:for "a-level"} (text/t :void.dash/level)]
       [:select {:name "level" :id "a-level"}
        ;(seq [l :in [:trace :debug :info :warn :error :fatal]]
           [:option {:value (string l) :selected (when (= :info l) true)} (string l)])]]
      [:div {:class "field"} [:button {:type "submit"} (text/t :void.dash/set)]]]
     [:p {:class "vd-absent"} (text/t :void.dash/actions-off)])])

(defn- params
  {:params [{:level :keyword? :ns :string?}] :ret @{:string (or :keyword :string :nil)}}
  "st, as the query table the filtered page's own links carry."
  [st]
  @{"level" (st :level) "ns" (st :ns)})

(defn logs-fragment
  {:params [{:level :keyword? :ns :string?}] :ret :any :throws [:string]}
  "The moving half: the matching records, newest last, capped for the
  page (the ring holds more than a page should)."
  [st]
  (def all (matching st))
  (def shown (if (> (length all) 200) (array/slice all -201) all))
  [:div (merge {:id "dash-logs"}
               (hx/get* (ctx/at "/logs" (params st)) :trigger "every 5s" :swap :outer-html))
   [:p {:class "vd-note"}
    (text/t :void.dash/logs-held {:count (ring/size records)
                                  :shown (length shown)
                                  :total (ring/size records)
                                  :capacity (records :capacity)})
    [:a {:href (ctx/at "/logs/tail")} (text/t :void.dash/sse-stream)]
    (text/t :void.dash/dropped {:dropped (log/dropped)})]
   (if (empty? shown)
     [:p {:class "vd-empty"} (text/t :void.dash/no-record)]
     [:pre {:class "dash-jdn dash-logs"}
      ;(seq [rec :in shown]
         [:span {:class (string "dash-log-" (string (get rec :level :info)))}
          (string (record-line rec) "\n")])])])

(defn logs-body
  {:params [{:level :keyword? :ns :string?} {:query {:string :any} & r}] :ret :any :throws [:string]}
  "The whole Logs page: filters, the moving fragment, the level form."
  [st req]
  [:div (view/live-attrs req "/logs/live")
   [:h1 (text/t :void.dash/logs)]
   (filter-panel st)
   (logs-fragment st)
   (level-form)])

(defn index
  {:params [{:query {:string :any} & r}]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "GET /logs: the level/namespace-filtered listing, htmx poll or full page."
  [req]
  (def st (listing-state req))
  (html/page (logs-body st req) {:layout view/layout :context {:request req}
                             :partial (fn [] (logs-fragment st))}))

# -- the live tail -------------------------------------------------------

(defn tail
  {:params [:any] :ret @{:status :number :body :any :headers @{:string :any}}}
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
  {:params [{:form (or {:string :string} :nil) & r}]
   :ret @{:status :number :headers @{:string :string} :body :string?}
   :throws [:string]}
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
