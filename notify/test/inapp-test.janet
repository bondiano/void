### The in-app channel end to end (ADR-0017): a real sqlite database
### under the store, the four routes driven through test/inject, and
### the one claim that matters more than the markup — **every answer is
### about the identity in the dyn**, so another recipient's row is not
### reachable by knowing its id.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/db :as db)
(import void/notify :as notify)
(import void/notify/inapp :as inapp)
(import void/notify/store :as store)
(import void/test :as test)
(require "void/notify/inapp")

(log/set-level! nil :error)

(def plugins
  ["void/http/init" "void/html/init"
   "void/db/init" "void/db-sqlite/init"
   "void/notify/init" "void/notify/inapp"])

(def db-path (string (or (os/getenv "TMPDIR") "/tmp")
                     "/void-notify-inapp-" (os/time) "-" (os/getpid) ".sqlite3"))

(def boot
  (test/start! {:plugins plugins
                :profile :test
                :only [:http/kernel :db/pool]
                :config {:env @{}
                         :cli {:log {:level :error}
                               :http {:port 0 :access-log false}
                               :db-sqlite {:path db-path}
                               :db {:n1-guard :off}}}}))

(defn- as [subject f]
  "Run f as somebody — the dyn void/auth publishes, bound by name."
  (with-dyns [inapp/identity-dyn {:subject subject}] (f)))

(defer (do (test/stop! boot) (os/rm db-path))
  (each stmt (store/tables) (db/run stmt))

  (assert (deep= @[:inapp] (notify/active)))

  # -- a notification becomes a row --------------------------------------

  (def result (notify/send {:key :order/shipped
                            :title "Your order shipped"
                            :body "Order #1042 is on its way."
                            :url "/orders/1042"
                            :data {:order 1042}
                            :to {:subject "user:42"}}))
  (assert (= :sent (get-in result [:results 0 :status])))

  (def rows (store/list-for "user:42"))
  (assert (= 1 (length rows)))
  (def row (first rows))
  (assert (= (result :id) (row :id))
          "the row id is the notification id, so a redelivery cannot make a second row")
  (assert (= :order/shipped (row :key)) "the key comes back a keyword")
  (assert (= 1042 (get-in row [:data :order])) "and :data survives the round trip through JSON")
  (assert (not (row :read?)))
  (assert (= 1 (store/unread-count "user:42")))

  # -- a notification with no subject is not this channel's business -----

  (def skipped (notify/send {:key :x :title "t" :to {:email "ada@example.com"}}))
  (assert (= :skipped (get-in skipped [:results 0 :status])))
  (assert (= 1 (length (store/list-for "user:42"))))

  # -- the panel and the bell --------------------------------------------

  (def c (test/client boot))

  (def panel (as "user:42" (fn [] (test/inject c {:uri "/notifications"}))))
  (assert (= 200 (panel :status)))
  (assert (string/find "Your order shipped" (test/text panel)))
  (assert (string/find "/orders/1042" (test/text panel))
          "a notification with a :url is a link — in a page the origin is the page's")
  (assert (not (string/find "<html" (test/text panel)))
          "the panel is a fragment: htmx swaps it into a page that already exists")

  (def badge (as "user:42" (fn [] (test/inject c {:uri "/notifications/badge"}))))
  (assert (= 200 (badge :status)))
  (assert (string/find ">1<" (test/text badge)) "the bell carries the unread count")

  # -- marking one read --------------------------------------------------

  (def marked (as "user:42"
                  (fn [] (test/inject c {:method :post
                                         :uri (string "/notifications/" (row :id) "/read")}))))
  (assert (= 200 (marked :status)))
  (assert (= 0 (store/unread-count "user:42")))
  (assert (get-in (store/list-for "user:42") [0 :read?]))
  (assert (not (store/mark-read! "user:42" (row :id)))
          "marking it again changes nothing, and says so")

  # -- somebody else's notification --------------------------------------

  (def theirs (notify/send {:key :x :title "Not for you" :to {:subject "user:43"}}))
  (assert (= 1 (store/unread-count "user:43")))
  (assert (empty? (filter |(= (theirs :id) ($ :id)) (store/list-for "user:42")))
          "a listing is about the caller and nobody else")
  (assert (nil? (store/find-for "user:42" (theirs :id)))
          "and knowing the id changes nothing — the recipient is part of every query")
  (assert (not (store/mark-read! "user:42" (theirs :id))))
  (assert (= 1 (store/unread-count "user:43")) "which is why their row is still unread")

  (def others (as "user:42"
                  (fn [] (test/inject c {:method :post
                                         :uri (string "/notifications/" (theirs :id) "/read")}))))
  (assert (= 200 (others :status))
          "the route answers with the caller's own panel — there is no id here that could address another inbox")
  (assert (= 1 (store/unread-count "user:43")))

  # -- mark all ----------------------------------------------------------

  (notify/send {:key :x :title "one" :to {:subject "user:42"}})
  (notify/send {:key :x :title "two" :to {:subject "user:42"}})
  (assert (= 2 (store/unread-count "user:42")))
  (def all (as "user:42" (fn [] (test/inject c {:method :post :uri "/notifications/read-all"}))))
  (assert (= 200 (all :status)))
  (assert (= 0 (store/unread-count "user:42")))
  (assert (= 1 (store/unread-count "user:43")) "and only the caller's")

  # -- an anonymous visitor ----------------------------------------------

  (assert (= 401 ((test/inject c {:uri "/notifications"}) :status))
          "notifications are personal: without an identity there is nobody to answer about")
  (assert (nil? (inapp/bell))
          "and the widget is absent rather than empty — there is no bell for nobody")

  # -- the per-notification override -------------------------------------

  (def overridden (notify/send {:key :x :title "In the letter it says this"
                                :to {:subject "user:42"}
                                :inapp {:title "In the bell it says this"}}))
  (assert (= "In the bell it says this"
             ((store/find-for "user:42" (overridden :id)) :title))
          "a notification can say one thing in the bell and another in the letter")

  # -- the views are vars ------------------------------------------------

  (def original inapp/badge-view)
  (set inapp/badge-view (fn [n] [:em "unread: " (string n)]))
  (def replaced (as "user:42" (fn [] (test/inject c {:uri "/notifications/badge"}))))
  (set inapp/badge-view original)
  (assert (string/find "<em>unread: " (test/text replaced))
          "an application replaces the bell by assignment")

  # -- the widget a layout carries ---------------------------------------

  (def markup (as "user:42" (fn [] (inapp/bell))))
  (assert markup "for a signed-in visitor there is one")
  (assert (deep= [:span {:class "void-notify"}] (tuple ;(slice markup 0 2)))
          "and it is ordinary hiccup — nothing here is a template engine of its own"))
