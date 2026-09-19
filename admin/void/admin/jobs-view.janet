### void/admin/jobs-view — the queue, as pages.
###
### Horizon and Sidekiq-web, at the scale of the eight functions
### `:void/jobs-backend` already answers. Nothing here asks the backend
### anything new: the depth table is `counts`, the listing is `list`
### filtered by queue, state and job, a record is `fetch`, and the two
### actions are `retry!` and `remove!`/`clear!`. A dashboard that had
### needed a ninth function would have been a dashboard that changed a
### contract three backends and one conformance suite implement.
###
### **The listing has a limit, not a page number.** `:list` takes
### `{:queue :state :job :parent :limit}` and no offset, so a pager
### here would either lie or grow the contract. It says how many rows
### it is showing and lets the operator ask for more — which is also
### the honest shape for a queue, where the rows move while you read
### them. It does not name an order either: `list` promises none, and
### the three backends do not agree on one.
###
### **A bulk needs a state.** `:clear!` selects by queue and state, and
### "everything" would include the jobs a worker is running right now.
### So the bulk bar appears only once a state is chosen, and retry is
### offered only on `:dead` — reviving a record a worker holds would
### run it twice.

(import void/jobs :as jobs)
(import ./context :as ctx)
(import ./text :as text)
(import ./view :as view)
(import ./widget :as widget)
(import void/htmx/hx :as hx)

(def path
  ``Where the section is mounted, under `[:admin :prefix]`. Fixed, for
  the reason `/metrics` and `/health` are fixed: the route table is
  built from static contributions, and a path from config would have
  to be read before the config exists. A resource that wants
  `/admin/jobs` for itself says so with its own `:path` — pages are
  mounted before resources, so this one would win.``
  "/jobs")

(defn title
  {:ret :string}
  "What the navigation and the page heading call it."
  []
  (text/t :void.admin/jobs))

(defn url
  {:params [:string? (or {:string :any} :nil)] :ret :string}
  "A URL in this section: (url), (url \"/-/bulk/retry\" params)."
  [&opt suffix query]
  (ctx/at (string path (or suffix "")) query))

# -- the state of a listing ----------------------------------------------

(defn params
  {:params [AdminJobsListing]
   :ret @{:string :any}}
  ``The query parameters that describe the current listing, so a
  filter link, the poll and a bulk confirmation all carry one view of
  it.``
  [st]
  @{"queue" (get st :queue)
    "state" (get st :state)
    "job" (get st :job)
    # only when it is not what [:admin :per-page] already says: a
    # parameter every link carries for no reason is a parameter an
    # operator has to read past to see the filter
    "limit" (when (not= (get st :limit) (get st :default-limit)) (get st :limit))})

(defn- with-params
  {:params [AdminJobsListing
            :any]
   :ret @{:string :any}}
  "The same parameters with some replaced — a nil drops the key, which
  is how \"this filter, without the queue\" is one expression."
  [st & kvs]
  (def p (params st))
  (var i 0)
  (while (< i (length kvs))
    (put p (kvs i) (kvs (inc i)))
    (+= i 2))
  p)

(def wrapper-id
  "The element the filter panel, the count links and the poll all
  swap — the depth table and the listing move together, because a
  retry changes both."
  "admin-jobs")

(defn- wrapper-swap
  {:params [:string] :ret @{:string :string} :throws [:string]}
  "The htmx half of anything that refetches the wrapper: into it,
  whole, and into the address bar."
  [href]
  (hx/get* href :target (string "#" wrapper-id) :swap :outer-html :push-url true))

(defn- swap-link
  {:params [:string :any] :ret :tuple :throws [:string]}
  "A link that swaps the wrapper rather than navigating."
  [href & body]
  [:a (merge {:href href} (wrapper-swap href)) ;body])

# -- the head of the page ------------------------------------------------

(defn total-of
  {:params [{:keyword {:keyword :number}} :keyword] :ret :number}
  "How many records are in one state, across every queue."
  [counts state]
  (var n 0)
  (eachp [_ per-state] counts
    (+= n (get per-state state 0)))
  n)

(defn- cards
  {:params [{:counts {:keyword {:keyword :number}} :backend {:keyword :any}
             :enqueued :number :duplicates :number & r}
            AdminJobsListing]
   :ret :tuple}
  "The four at-a-glance cards: the backend, the backlog, the dead
  letter queue and this process's own enqueue counter."
  [snap st]
  (def caps (snap :backend))
  (def dead (total-of (snap :counts) :dead))
  [:div {:class "vd-cards"}
   [:div {:class "vd-card"}
    [:h2 (text/t :void.admin/jobs-backend)]
    [:p (string (caps :name))]
    [:p {:class "vd-note"}
     (text/t :void.admin/jobs-backend-note
             {:sharing (text/t (if (caps :shared)
                                 :void.admin/jobs-shared
                                 :void.admin/jobs-this-process))
              :flows (widget/text-of (truthy? (caps :flows)))
              :rate (string (caps :rate-limit))
              :locks (string (caps :locks))})]]
   [:div {:class "vd-card"}
    [:h2 (text/t :void.admin/jobs-backlog)]
    # what still owes work is the queue's own list, not a list of three
    # states spelled again here
    [:p {:class "vd-count"}
     (string (sum (seq [s :in jobs/record-live-states] (total-of (snap :counts) s))))]
    [:p {:class "vd-note"}
     (string/join (map string jobs/record-live-states) ", ")]]
   [:div {:class "vd-card"}
    [:h2 (text/t :void.admin/jobs-dead)]
    [:p {:class "vd-count"}
     (if (zero? dead)
       "0"
       (swap-link (url "" (with-params st "state" :dead "queue" nil)) (string dead)))]
    [:p {:class "vd-note"} (text/t :void.admin/jobs-dead-note)]]
   [:div {:class "vd-card"}
    [:h2 (text/t :void.admin/jobs-enqueued)]
    [:p {:class "vd-count"} (string (get snap :enqueued 0))]
    # a counter in this process's heap, not in the backend: on a fleet
    # every replica has its own, and the card says so rather than
    # letting the number read as the queue's
    [:p {:class "vd-note"}
     (text/t :void.admin/jobs-enqueued-note {:duplicates (get snap :duplicates 0)})]]])

(defn- depth-cell
  {:params [AdminJobsListing
            :any :keyword :number]
   :ret :tuple :throws [:string]}
  "One [queue x state] depth cell — a plain 0, or a link that swaps
  the whole wrapper to that filter."
  [st qname state n]
  [:td {:class "vd-count"}
   (if (zero? n)
     "0"
     (swap-link (url "" (with-params st "queue" qname "state" state)) (string n)))])

(defn- depth-table
  {:params [{:counts {:keyword {:keyword :number}} & r}
            AdminJobsListing]
   :ret :tuple :throws [:string]}
  "Every queue's depth, one row per queue and one column per state."
  [snap st]
  (def counts (snap :counts))
  (def queues (sorted (keys counts)))
  [:table {:class "vd-table"}
   [:thead
    [:tr [:th "queue"] ;(seq [s :in jobs/record-states] [:th (string s)])]]
   [:tbody
    (if (empty? queues)
      [:tr [:td {:colspan (inc (length jobs/record-states)) :class "vd-empty"}
            (text/t :void.admin/jobs-empty)]]
      (seq [q :in queues]
        [:tr
         [:th (swap-link (url "" (with-params st "queue" q "state" nil)) (string q))]
         ;(seq [s :in jobs/record-states]
            (depth-cell st q s (get-in counts [q s] 0)))]))]
   (when (> (length queues) 1)
     [:tfoot
      [:tr [:th (text/t :void.admin/jobs-all)]
       ;(seq [s :in jobs/record-states]
          [:td {:class "vd-count"} (string (total-of counts s))])]])])

# -- the filter panel ----------------------------------------------------

(defn- option
  {:params [:any :any :any] :ret :tuple}
  "One <option>, selected when it reads the same as the current value."
  [value selected caption]
  [:option {:value (string value)
            :selected (when (= (string value) (string (or selected ""))) true)}
   caption])

(defn- select-field
  {:params [:string :any [:any] :any] :ret :tuple}
  "A <select> filter field: 'any', plus one option per value."
  [name caption options value]
  (def id (string "f-jobs-" name))
  [:div {:class "field"}
   [:label {:for id} caption]
   [:select {:name name :id id}
    (option "" value (text/t :void.admin/any))
    ;(seq [o :in options] (option o value (string o)))]])

(defn- filter-panel
  {:params [{:queues @[:keyword] :jobs @[:keyword] & r}
            AdminJobsListing]
   :ret :tuple :throws [:string]}
  "Queue, state, job and row-limit — the four filters, submitting on
  every change and swapping the wrapper rather than reloading."
  [snap st]
  [:form (merge {:id "admin-jobs-filters"
                 :method "get"
                 :action (url)
                 :class "vd-toolbar"}
                (wrapper-swap (url))
                (hx/attrs :trigger "change, submit"))
   (select-field "queue" (text/t :void.admin/jobs-queue) (snap :queues) (st :queue))
   (select-field "state" (text/t :void.admin/jobs-state) jobs/record-states (st :state))
   (select-field "job" (text/t :void.admin/jobs-job) (snap :jobs) (st :job))
   [:div {:class "field"}
    [:label {:for "f-jobs-limit"} (text/t :void.admin/jobs-rows)]
    [:input {:type "number" :name "limit" :id "f-jobs-limit" :min "1"
             :value (string (st :limit))}]]
   [:div {:class "field"} [:button {:type "submit"} (text/t :void.admin/filter)]]])

# -- the listing ---------------------------------------------------------

(defn- action-button
  {:params [:any :string :any :any] :ret :tuple :throws [:string]}
  "One record action as its own tiny form — retry or discard, POSTing
  to the section's own route."
  [id action caption danger?]
  (view/post-form :post (url (string "/" id "/-/" action)) {:class "vd-inline"}
    [:button {:type "submit" :class (when danger? "danger")} caption]))

(defn- row-actions
  {:params [{:id :any :state (or :keyword :nil) & r}] :ret :tuple :throws [:string]}
  "Retry (dead only) and discard, for one row of the listing."
  [r]
  [:td
   (when (= :dead (get r :state))
     (action-button (r :id) "retry" (text/t :void.admin/jobs-retry) false))
   " "
   (action-button (r :id) "discard" (text/t :void.admin/jobs-discard) true)])

(defn- age-cell
  {:params [{:run-at :any :state (or :keyword :nil) :finished-at :any :started-at :any
             :enqueued-at :any & r}
            :number]
   :ret :tuple}
  ``How long ago something happened to this record — except for a
  pending one whose `:run-at` is still ahead, where the useful number
  is how long until it may be claimed. "waiting 3h" and "runs in 3h"
  are the difference between a queue that is stuck and a queue that is
  doing what it was told, and both are `:pending`.``
  [r now]
  (def run-at (get r :run-at))
  (if (and (= :pending (get r :state)) (number? run-at) (> run-at now))
    [:td (string "in " (jobs/record-age now run-at))]
    [:td (jobs/record-age (or (get r :finished-at)
                              (get r :started-at)
                              (get r :enqueued-at))
                          now)]))

(defn- error-cell
  {:params [{:error (or :string :nil) & r}] :ret :tuple}
  "The failure text, truncated — or the em dash of no failure."
  [r]
  (def e (get r :error))
  [:td (if e
         [:code (if (> (length e) 80) (string (string/slice e 0 80) "…") e)]
         (widget/text-of nil))])

(defn- rows-table
  {:params [[{:keyword :any}] :number :boolean?]
   :ret :tuple :throws [:string]}
  ``The listing. `actions?` is false on the sample a confirmation
  shows: a page asking "shall I do this to these records" must not
  also offer to do something else to one of them.``
  [rows now &opt actions?]
  (default actions? true)
  [:table {:class "vd-table"}
   [:thead
    [:tr [:th "id"] [:th "state"] [:th "queue"] [:th "job"]
     [:th "attempt"] [:th "age"] [:th "error"] (when actions? [:th ""])]]
   [:tbody
    (if (empty? rows)
      [:tr [:td {:colspan (if actions? 8 7) :class "vd-empty"}
            (text/t :void.admin/jobs-no-record)]]
      (seq [r :in rows]
        [:tr {:id (string "job-" (r :id))}
         [:td [:a {:href (url (string "/" (r :id)))} (string (r :id))]]
         [:td (string (get r :state))]
         [:td (string (get r :queue))]
         [:td (string (get r :job))]
         [:td {:class "vd-count"}
          (string (get r :attempt 0) "/" (get r :max-attempts 0))]
         (age-cell r now)
         (error-cell r)
         (when actions? (row-actions r))]))]])

(defn- bulk-bar
  {:params [AdminJobsListing
            :number]
   :ret (or :tuple :nil)}
  ``The two bulk actions, and the one line of arithmetic behind when
  they are offered: `counts` and `clear!` select by queue and state, so
  that is what a bulk here selects by — the job filter is dropped from
  the link rather than silently ignored behind it.``
  [st shown]
  (when (and (st :state) (pos? shown))
    (def sel (with-params st "job" nil "limit" nil))
    [:div {:class "vd-actions"}
     [:span (if (st :queue)
              (text/t :void.admin/jobs-with-every-in-queue
                      {:state (string (st :state)) :queue (string (st :queue))})
              (text/t :void.admin/jobs-with-every {:state (string (st :state))}))]
     (when (= :dead (st :state))
       [:a {:class "vd-button" :href (url "/-/bulk/retry" sel)}
        (text/t :void.admin/jobs-retry-all)])
     [:a {:class "vd-button danger" :href (url "/-/bulk/discard" sel)}
      (text/t :void.admin/jobs-discard-all)]]))

(defn- dead-banner
  {:params [{:counts {:keyword {:keyword :number}} & r}
            AdminJobsListing]
   :ret (or :tuple :nil) :throws [:string]}
  "A warning banner when there are dead records and the listing is
  not already showing them."
  [snap st]
  (def n (total-of (snap :counts) :dead))
  (when (and (pos? n) (not= :dead (st :state)))
    [:div {:class "vd-warn"}
     (text/t :void.admin/jobs-dead-banner {:count n})
     (swap-link (url "" (with-params st "state" :dead "queue" nil))
                (text/t :void.admin/jobs-open-dead))]))

(defn body-fragment
  {:params [{:counts {:keyword {:keyword :number}} :backend {:keyword :any}
             :enqueued :number :duplicates :number & r}
            [{:keyword :any}]
            AdminJobsListing
            :number]
   :ret :tuple :throws [:string]}
  ``Everything a change moves: the cards, the depth table and the
  listing. It re-fetches itself every few seconds — an operator
  watching a queue drain asked for exactly that — and the filter panel
  stays outside it, so a poll never takes the cursor out of a field.``
  [snap rows st now]
  (def here (url "" (params st)))
  [:div (merge {:id wrapper-id} (hx/get* here :trigger "every 5s" :swap :outer-html))
   (cards snap st)
   (dead-banner snap st)
   [:h2 (text/t :void.admin/jobs-queues)]
   (depth-table snap st)
   [:h2 (text/t :void.admin/jobs-records)]
   (bulk-bar st (length rows))
   (rows-table rows now)
   # not "the newest N": `list` takes a limit and says nothing about
   # order, and the three backends do not agree on one — the db lists
   # newest first, the other two oldest first. Claiming an order the
   # contract does not promise is how a page starts lying
   [:p {:class "vd-note"}
    (string (text/t :void.admin/jobs-shown {:count (length rows)})
            (if (>= (length rows) (st :limit))
              (text/t :void.admin/jobs-limited {:limit (st :limit)})
              ""))]])

(defn index-page
  {:params [{:queues @[:keyword] :jobs @[:keyword]
             :counts {:keyword {:keyword :number}} :backend {:keyword :any}
             :enqueued :number :duplicates :number & r}
            [{:keyword :any}]
            AdminJobsListing
            :number]
   :ret :tuple :throws [:string]}
  "The section: the filter panel, and everything it filters."
  [snap rows st now]
  [:div
   [:h1 (title)]
   (filter-panel snap st)
   (body-fragment snap rows st now)])

(defn notice-page
  {:params [:any] :ret :tuple}
  ``A refusal a person can read. The built-in error page is terse
  outside dev, and these two refusals are not accidents — they are the
  answer to a URL that asks for something the queue will not do, and
  the reason is the whole of the answer.``
  [message]
  [:div
   [:h1 (title)]
   [:div {:class "vd-warn"} [:p message]]
   [:p [:a {:href (url)} (text/t :void.admin/jobs-back)]]])

# -- one record ----------------------------------------------------------

(def- time-fields
  {:run-at true :enqueued-at true :started-at true :finished-at true
   :unique-until true :claimed-at true})

(defn- stamp
  {:params [:number :number] :ret :string}
  "One timestamp field: the date, and its age next to it."
  [t now]
  (def d (os/date (math/floor t) true))
  (string/format "%04d-%02d-%02d %02d:%02d:%02dZ (%s)"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)
                 (jobs/record-age t now)))

(defn- field-value
  {:params [:keyword :any :number] :ret :string}
  "One field of a record, drawn by what kind of field it is: a
  timestamp, the failure count, or the default text projection."
  [k v now]
  (cond
    (nil? v) (widget/text-of nil)
    (in time-fields k) (stamp v now)
    (= :failures k) (string (length v))
    (widget/text-of v)))

(defn record-page
  {:params [{:id :any :state (or :keyword :nil) & r} :number]
   :ret :tuple :throws [:string]}
  "One record: every field the queue stores for it, its failures, and
  the two things an operator can do about it."
  [r now]
  [:div
   [:h1 (text/t :void.admin/jobs-one {:id (r :id)})]
   [:div {:class "vd-actions"}
    (when (= :dead (get r :state))
      (action-button (r :id) "retry" (text/t :void.admin/jobs-retry) false))
    (action-button (r :id) "discard" (text/t :void.admin/jobs-discard) true)
    # a plain link, not a swap: the element the listing's links target
    # is not on this page, and htmx with a target it cannot find does
    # nothing at all — including not following the href
    [:a {:href (url)} (text/t :void.admin/jobs-back)]]
   [:table {:class "vd-table"}
    [:tbody
     (seq [k :in jobs/record-fields :when (not (nil? (get r k)))]
       [:tr [:th (string k)] [:td (field-value k (get r k) now)]])]]
   (unless (empty? (get r :failures []))
     [:div
      [:h2 (text/t :void.admin/jobs-failures)]
      [:table {:class "vd-table"}
       [:thead [:tr [:th "attempt"] [:th "when"] [:th "error"]]]
       [:tbody
        (seq [f :in (get r :failures [])]
          [:tr
           [:td {:class "vd-count"} (string (get f :attempt))]
           [:td (stamp (get f :at 0) now)]
           [:td [:code (string (get f :error))]]])]]])])

# -- the confirmation ----------------------------------------------------

(defn confirm-page
  {:params [:keyword
            AdminJobsListing
            :number [{:keyword :any}] :number]
   :ret :tuple :throws [:string]}
  ``What a bulk goes through, for the reason the resource bulk goes
  through one: the number is counted on the server, and it is the same
  road whether it is one record or forty thousand.``
  [action st total sample now]
  (def verb (text/t (if (= :retry action)
                      :void.admin/jobs-retry
                      :void.admin/jobs-discard)))
  (def where
    (if (st :queue)
      (text/t :void.admin/jobs-queue-suffix {:queue (string (st :queue))})
      (text/t :void.admin/jobs-every-queue-suffix)))
  [:div
   [:h1 (text/t :void.admin/jobs-confirm-title {:action verb})]
   # one sentence, count inside: a number pinned to the front of a
   # translated clause is a number some language has to read around
   [:p {:class "vd-count"}
    (text/t (if (= :retry action)
              :void.admin/jobs-retry-count
              :void.admin/jobs-discard-count)
            {:count total :state (string (st :state)) :queue where})]
   (when (not (empty? sample))
     (rows-table sample now false))
   (if (zero? total)
     [:p {:class "vd-empty"} (text/t :void.admin/jobs-nothing-matches)]
     (view/post-form :post (url (string "/-/bulk/" action)) {:class "vd-form"}
       ;(seq [[k v] :pairs (params st) :when (not (nil? v))]
          [:input {:type "hidden" :name k :value (string v)}])
       [:div {:class "vd-actions"}
        [:button {:type "submit"
                  :class (if (= :retry action) "primary" "danger")}
         (text/t :void.admin/jobs-confirm-yes
                 {:action (string/ascii-lower verb) :count total})]
        [:a {:href (url "" (params st))} (text/t :void.admin/cancel)]]))])
