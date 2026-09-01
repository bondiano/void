### void/notify/store — the in-app notification, as rows (ADR-0040 §6).
###
### One table, and void owns it — unlike the users table `void/auth-db`
### reads and unlike the notification itself, which is a value that
### belongs to nobody. It comes as **DDL data** rather than as a
### migration file, for the reason ADR-0009 gives and `void/auth-db`
### follows: a migration timeline belongs to the application. One file
### in `db/migrations`:
###
###     (import void/notify/store :as notify-store)
###     (defn up [] (notify-store/tables))
###     (defn down [] (notify-store/drop-tables))
###
### and `void/db/builder` compiles it for whichever engine is running.
###
### **Every function here takes the recipient**, and the routes above
### take it from the identity in the dyn rather than from the request.
### A notification list keyed by a parameter is somebody else's inbox
### one guessed id away, and the way not to write that bug is to have
### no function that could.
###
### `seen` rather than a `read` flag, and the column is nullable:
### "unread" is the absence of a moment, so the same column answers
### "is it unread" and "when did they see it" — and `read` is a
### reserved word in more engines than it is not.

(import spork/json)
(import void/db :as db)

(def defaults
  "Defaults of the [:notify-inapp] keys this module reads."
  {:table "notifications"})

(defn- table-name [&opt cfg]
  (get (merge defaults (or cfg {})) :table))

(defn tables
  ``The table void owns, as `void/db/builder` statements — put them in
  a migration of the application's own. `cfg` is the [:notify-inapp]
  slice, when the table name was changed.``
  [&opt cfg]
  (def t (table-name cfg))
  [{:create-table t
    :columns [[:id :text {:primary-key true}]
              # the subject an identity carries — "user:42" — and not a
              # foreign key: void does not know what a user is (ADR-0023)
              [:recipient :text {:null false}]
              [:key :text {:null false}]
              [:title :text {:null false}]
              [:body :text]
              [:url :text]
              # JSON, because the payload is the application's shape and
              # both engines store it as text either way
              [:data :text]
              [:created :int {:null false}]
              [:seen :int]]}
   # the one query the bell makes on every poll, and the one the panel
   # makes when it opens: both are (recipient, created desc)
   {:create-index (string t "_recipient_idx") :on t :columns [:recipient :created]}])

(defn drop-tables
  "The other direction, for a migration's `down`."
  [&opt cfg]
  [{:drop-table (table-name cfg)}])

# -- rows in and out -----------------------------------------------------

(defn- json-out [value]
  (when (and (dictionary? value) (not (empty? value)))
    (json/encode value)))

(defn- json-in [text]
  (when (and text (not (empty? (string text))))
    (def [ok value] (protect (json/decode text true)))
    (when ok value)))

(defn row->record
  "A row as the views read it: `:key` back to a keyword, `:data` back
  to a table, `:read?` the question the template asks."
  [row]
  (when row
    {:id (row :id)
     :recipient (row :recipient)
     :key (keyword (row :key))
     :title (row :title)
     :body (row :body)
     :url (row :url)
     :data (or (json-in (row :data)) {})
     :created (row :created)
     :seen (row :seen)
     :read? (not (nil? (row :seen)))}))

(defn record!
  ``Write one notification into `recipient`'s list. The row id **is**
  the notification id, so the letter, the webhook body and this row all
  name the same event — and a redelivery of the same notification
  cannot make a second row.``
  [note recipient &opt cfg]
  (def t (keyword (table-name cfg)))
  (db/execute! {:insert t
                :values [{:id (note :id)
                          :recipient recipient
                          :key (string (note :key))
                          :title (note :title)
                          :body (get note :body)
                          :url (get note :url)
                          :data (json-out (get note :data))
                          # :seen is left out rather than set: unread
                          # is the absence of a moment
                          :created (get note :at (os/time))}]})
  (note :id))

# -- what the bell and the panel ask -------------------------------------

(defn unread-count
  "How many unread notifications `recipient` has — the number in the
  bell, and a count rather than a list because that is all it shows."
  [recipient &opt cfg]
  (def t (keyword (table-name cfg)))
  (or (db/value {:select [[:raw "count(*) AS n"]] :from t
                 :where [:and [:= :recipient recipient] [:= :seen db/null]]})
      0))

(defn list-for
  ``A recipient's notifications, newest first. `opts`: `:limit` (25),
  `:unread` (only the unread ones).``
  [recipient &opt opts cfg]
  (default opts {})
  (def t (keyword (table-name cfg)))
  (def where
    (if (get opts :unread)
      [:and [:= :recipient recipient] [:= :seen db/null]]
      [:= :recipient recipient]))
  (map row->record
       (db/query-sql {:select [:*] :from t
                      :where where
                      :order-by [[:created :desc] [:id :desc]]
                      :limit (get opts :limit 25)})))

(defn find-for
  "One of `recipient`'s notifications by id, or nil — nil for a row
  that exists and belongs to somebody else, which is the same answer
  for the same reason."
  [recipient id &opt cfg]
  (def t (keyword (table-name cfg)))
  (row->record (db/one-row {:select [:*] :from t
                            :where {:id id :recipient recipient}
                            :limit 1})))

(defn mark-read!
  "Mark one of `recipient`'s notifications read. Returns whether a row
  changed — false for somebody else's id, and for one already read."
  [recipient id &opt at cfg]
  (default at (os/time))
  (def t (keyword (table-name cfg)))
  (pos? (db/execute! {:update t
                      :set {:seen at}
                      :where [:and [:= :id id] [:= :recipient recipient]
                              [:= :seen db/null]]})))

(defn mark-all-read!
  "Mark everything `recipient` has not read as read. Returns how many
  rows changed."
  [recipient &opt at cfg]
  (default at (os/time))
  (def t (keyword (table-name cfg)))
  (db/execute! {:update t
                :set {:seen at}
                :where [:and [:= :recipient recipient] [:= :seen db/null]]}))

(defn delete-for!
  "Remove one of `recipient`'s notifications. What a person's own
  \"clear\" button calls, and what an account deletion loops over."
  [recipient id &opt cfg]
  (def t (keyword (table-name cfg)))
  (pos? (db/execute! {:delete t :where {:id id :recipient recipient}})))
