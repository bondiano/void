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
(import ./view :as view)
(import ./widget :as widget)

(def path
  ``Where the section is mounted, under `[:admin :prefix]`. Fixed, for
  the reason `/metrics` and `/health` are fixed: the route table is
  built from static contributions, and a path from config would have
  to be read before the config exists. A resource that wants
  `/admin/jobs` for itself says so with its own `:path` — pages are
  mounted before resources, so this one would win.``
  "/jobs")

(def title "What the navigation and the page heading call it." "Jobs")

(defn url
  "A URL in this section: (url), (url \"/-/bulk/retry\" params)."
  [&opt suffix query]
  (ctx/at (string path (or suffix "")) query))

# -- the state of a listing ----------------------------------------------

(defn params
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

(defn- swap-link [href & body]
  [:a {:href href
       :hx-get href
       :hx-target (string "#" wrapper-id)
       :hx-swap "outerHTML"
       :hx-push-url "true"}
   ;body])

# -- the head of the page ------------------------------------------------

(defn total-of
  "How many records are in one state, across every queue."
  [counts state]
  (var n 0)
  (eachp [_ per-state] counts
    (+= n (get per-state state 0)))
  n)

(defn- cards [snap st]
  (def caps (snap :backend))
  (def dead (total-of (snap :counts) :dead))
  [:div {:class "admin-cards"}
   [:div {:class "admin-card"}
    [:h2 "Backend"]
    [:p (string (caps :name))]
    [:p {:class "admin-note"}
     (string (if (caps :shared) "shared" "this process only")
             " · flows " (if (caps :flows) "yes" "no")
             " · rate limit " (string (caps :rate-limit))
             " · locks " (string (caps :locks)))]]
   [:div {:class "admin-card"}
    [:h2 "Backlog"]
    # what still owes work is the queue's own list, not a list of three
    # states spelled again here
    [:p {:class "admin-count"}
     (string (sum (seq [s :in jobs/record-live-states] (total-of (snap :counts) s))))]
    [:p {:class "admin-note"}
     (string/join (map string jobs/record-live-states) ", ")]]
   [:div {:class "admin-card"}
    [:h2 "Dead"]
    [:p {:class "admin-count"}
     (if (zero? dead)
       "0"
       (swap-link (url "" (with-params st "state" :dead "queue" nil)) (string dead)))]
    [:p {:class "admin-note"} "out of attempts, or killed by hand"]]
   [:div {:class "admin-card"}
    [:h2 "Enqueued"]
    [:p {:class "admin-count"} (string (get snap :enqueued 0))]
    # a counter in this process's heap, not in the backend: on a fleet
    # every replica has its own, and the card says so rather than
    # letting the number read as the queue's
    [:p {:class "admin-note"}
     (string "by this process since it started · "
             (get snap :duplicates 0) " refused by a unique key")]]])

(defn- depth-cell [st qname state n]
  [:td {:class "admin-count"}
   (if (zero? n)
     "0"
     (swap-link (url "" (with-params st "queue" qname "state" state)) (string n)))])

(defn- depth-table [snap st]
  (def counts (snap :counts))
  (def queues (sorted (keys counts)))
  [:table {:class "admin-table"}
   [:thead
    [:tr [:th "queue"] ;(seq [s :in jobs/record-states] [:th (string s)])]]
   [:tbody
    (if (empty? queues)
      [:tr [:td {:colspan (inc (length jobs/record-states)) :class "admin-empty"}
            "The queue holds nothing."]]
      (seq [q :in queues]
        [:tr
         [:th (swap-link (url "" (with-params st "queue" q "state" nil)) (string q))]
         ;(seq [s :in jobs/record-states]
            (depth-cell st q s (get-in counts [q s] 0)))]))]
   (when (> (length queues) 1)
     [:tfoot
      [:tr [:th "all"]
       ;(seq [s :in jobs/record-states]
          [:td {:class "admin-count"} (string (total-of counts s))])]])])

# -- the filter panel ----------------------------------------------------

(defn- option [value selected label]
  [:option {:value (string value)
            :selected (when (= (string value) (string (or selected ""))) true)}
   label])

(defn- select-field [name label options value]
  (def id (string "f-jobs-" name))
  [:div {:class "field"}
   [:label {:for id} label]
   [:select {:name name :id id}
    (option "" value "any")
    ;(seq [o :in options] (option o value (string o)))]])

(defn- filter-panel [snap st]
  [:form {:id "admin-jobs-filters"
          :method "get"
          :action (url)
          :class "admin-toolbar"
          :hx-get (url)
          :hx-target (string "#" wrapper-id)
          :hx-swap "outerHTML"
          :hx-push-url "true"
          :hx-trigger "change, submit"}
   (select-field "queue" "Queue" (snap :queues) (st :queue))
   (select-field "state" "State" jobs/record-states (st :state))
   (select-field "job" "Job" (snap :jobs) (st :job))
   [:div {:class "field"}
    [:label {:for "f-jobs-limit"} "Rows"]
    [:input {:type "number" :name "limit" :id "f-jobs-limit" :min "1"
             :value (string (st :limit))}]]
   [:div {:class "field"} [:button {:type "submit"} "Filter"]]])

# -- the listing ---------------------------------------------------------

(defn- action-button [id action label danger?]
  (view/post-form :post (url (string "/" id "/-/" action)) {:class "admin-act"}
    [:button {:type "submit" :class (when danger? "danger")} label]))

(defn- row-actions [r]
  [:td
   (when (= :dead (get r :state)) (action-button (r :id) "retry" "Retry" false))
   " "
   (action-button (r :id) "discard" "Discard" true)])

(defn- age-cell
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

(defn- error-cell [r]
  (def e (get r :error))
  [:td (if e
         [:code (if (> (length e) 80) (string (string/slice e 0 80) "…") e)]
         (widget/text-of nil))])

(defn- rows-table
  ``The listing. `actions?` is false on the sample a confirmation
  shows: a page asking "shall I do this to these records" must not
  also offer to do something else to one of them.``
  [rows now &opt actions?]
  (default actions? true)
  [:table {:class "admin-table"}
   [:thead
    [:tr [:th "id"] [:th "state"] [:th "queue"] [:th "job"]
     [:th "attempt"] [:th "age"] [:th "error"] (when actions? [:th ""])]]
   [:tbody
    (if (empty? rows)
      [:tr [:td {:colspan (if actions? 8 7) :class "admin-empty"} "No record matches."]]
      (seq [r :in rows]
        [:tr {:id (string "job-" (r :id))}
         [:td [:a {:href (url (string "/" (r :id)))} (string (r :id))]]
         [:td (string (get r :state))]
         [:td (string (get r :queue))]
         [:td (string (get r :job))]
         [:td {:class "admin-count"}
          (string (get r :attempt 0) "/" (get r :max-attempts 0))]
         (age-cell r now)
         (error-cell r)
         (when actions? (row-actions r))]))]])

(defn- bulk-bar
  ``The two bulk actions, and the one line of arithmetic behind when
  they are offered: `counts` and `clear!` select by queue and state, so
  that is what a bulk here selects by — the job filter is dropped from
  the link rather than silently ignored behind it.``
  [st shown]
  (when (and (st :state) (pos? shown))
    (def sel (with-params st "job" nil "limit" nil))
    [:div {:class "admin-actions"}
     [:span (string "With every " (string (st :state)) " record"
                    (if (st :queue) (string " in " (string (st :queue))) " in every queue")
                    ":")]
     (when (= :dead (st :state))
       [:a {:class "admin-button" :href (url "/-/bulk/retry" sel)} "Retry all"])
     [:a {:class "admin-button danger" :href (url "/-/bulk/discard" sel)} "Discard all"]]))

(defn- dead-banner [snap st]
  (def n (total-of (snap :counts) :dead))
  (when (and (pos? n) (not= :dead (st :state)))
    [:div {:class "admin-warn"}
     (string n " job" (if (= 1 n) " is" "s are") " dead. ")
     (swap-link (url "" (with-params st "state" :dead "queue" nil))
                "Open the dead letter queue")]))

(defn body-fragment
  ``Everything a change moves: the cards, the depth table and the
  listing. It re-fetches itself every few seconds — an operator
  watching a queue drain asked for exactly that — and the filter panel
  stays outside it, so a poll never takes the cursor out of a field.``
  [snap rows st now]
  (def here (url "" (params st)))
  [:div {:id wrapper-id
         :hx-get here
         :hx-trigger "every 5s"
         :hx-swap "outerHTML"}
   (cards snap st)
   (dead-banner snap st)
   [:h2 "Queues"]
   (depth-table snap st)
   [:h2 "Records"]
   (bulk-bar st (length rows))
   (rows-table rows now)
   # not "the newest N": `list` takes a limit and says nothing about
   # order, and the three backends do not agree on one — the db lists
   # newest first, the other two oldest first. Claiming an order the
   # contract does not promise is how a page starts lying
   [:p {:class "admin-note"}
    (string (length rows) " record" (if (= 1 (length rows)) "" "s") " shown"
            (if (>= (length rows) (st :limit))
              (string " — the first " (st :limit) " the backend hands back for this "
                      "filter. `list` takes a limit and no offset, so there is no page "
                      "two: ask for more rows above, or narrow the filter")
              ""))]])

(defn index-page
  "The section: the filter panel, and everything it filters."
  [snap rows st now]
  [:div
   [:h1 title]
   (filter-panel snap st)
   (body-fragment snap rows st now)])

(defn notice-page
  ``A refusal a person can read. The built-in error page is terse
  outside dev, and these two refusals are not accidents — they are the
  answer to a URL that asks for something the queue will not do, and
  the reason is the whole of the answer.``
  [message]
  [:div
   [:h1 title]
   [:div {:class "admin-warn"} [:p message]]
   [:p [:a {:href (url)} "Back to the queue"]]])

# -- one record ----------------------------------------------------------

(def- time-fields
  {:run-at true :enqueued-at true :started-at true :finished-at true
   :unique-until true :claimed-at true})

(defn- stamp [t now]
  (def d (os/date (math/floor t) true))
  (string/format "%04d-%02d-%02d %02d:%02d:%02dZ (%s)"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)
                 (jobs/record-age t now)))

(defn- field-value [k v now]
  (cond
    (nil? v) (widget/text-of nil)
    (in time-fields k) (stamp v now)
    (= :failures k) (string (length v))
    (widget/text-of v)))

(defn record-page
  "One record: every field the queue stores for it, its failures, and
  the two things an operator can do about it."
  [r now]
  [:div
   [:h1 (string "Job " (r :id))]
   [:div {:class "admin-actions"}
    (when (= :dead (get r :state)) (action-button (r :id) "retry" "Retry" false))
    (action-button (r :id) "discard" "Discard" true)
    # a plain link, not a swap: the element the listing's links target
    # is not on this page, and htmx with a target it cannot find does
    # nothing at all — including not following the href
    [:a {:href (url)} "Back to the queue"]]
   [:table {:class "admin-table"}
    [:tbody
     (seq [k :in jobs/record-fields :when (not (nil? (get r k)))]
       [:tr [:th (string k)] [:td (field-value k (get r k) now)]])]]
   (unless (empty? (get r :failures []))
     [:div
      [:h2 "Failures"]
      [:table {:class "admin-table"}
       [:thead [:tr [:th "attempt"] [:th "when"] [:th "error"]]]
       [:tbody
        (seq [f :in (get r :failures [])]
          [:tr
           [:td {:class "admin-count"} (string (get f :attempt))]
           [:td (stamp (get f :at 0) now)]
           [:td [:code (string (get f :error))]]])]]])])

# -- the confirmation ----------------------------------------------------

(defn confirm-page
  ``What a bulk goes through, for the reason the resource bulk goes
  through one: the number is counted on the server, and it is the same
  road whether it is one record or forty thousand.``
  [action st total sample now]
  (def label (if (= :retry action) "Retry" "Discard"))
  [:div
   [:h1 (string label " — confirm")]
   [:p [:span {:class "admin-count"} (string total)]
    (string " " (string (st :state)) " record" (if (= 1 total) "" "s")
            (if (st :queue) (string " in queue " (string (st :queue))) " in every queue")
            (if (= :retry action)
              " will go back to the front of the queue with their attempts reset."
              " will be dropped. A dropped record is gone: nothing keeps it elsewhere."))]
   (when (not (empty? sample))
     (rows-table sample now false))
   (if (zero? total)
     [:p {:class "admin-empty"} "Nothing matches, so there is nothing to do."]
     (view/post-form :post (url (string "/-/bulk/" action)) {:class "admin-form"}
       ;(seq [[k v] :pairs (params st) :when (not (nil? v))]
          [:input {:type "hidden" :name k :value (string v)}])
       [:div {:class "admin-actions"}
        [:button {:type "submit"
                  :class (if (= :retry action) "primary" "danger")}
         (string "Yes, " (string/ascii-lower label) " " total
                 " record" (if (= 1 total) "" "s"))]
        [:a {:href (url "" (params st))} "Cancel"]]))])
