### B3 — Postgres + hiccup SSR ~15KB. Budget: p50 < 5ms, p99 < 20ms, ≥ 1.5k RPS
### (1 worker, 1 vCPU).
###
### The shape a void application actually is: a query, a page of
### hiccup built from its rows, and the HTML on the wire. It reads the
### same table B2 reads, so the difference between the two rows is the
### rendering and nothing else — a different query in each would make
### the delta unreadable.
###
### This is also the profile the GC budget is stated against ("max
### pause < 10 ms on the B3 profile"), and for good reason: 15KB of
### markup per request is where a stop-the-world collector shows up.
### It has nowhere to hide — a GC pause on a single-threaded loop *is*
### loop lag, and the probe in this app measures that (see
### void/bench/probe).
###
### Needs a server: VOID_BENCH_PG (or VOID_TEST_PG). PORT overrides
### the listen port (default 8103).

(import ../prelude)
(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/html :as html)
(import void/db :as db)
(import void/bench/pg :as pg)
(import void/bench/seed :as seed)
(require "void/http/init")
(require "void/html/init")
(require "void/db/init")
(require "void/db-postgres/init")
(require "void/bench/probe")

(def page-size
  "Rows per page. Sized so the rendered document lands near the 15KB
  the budget names — see the app test, which pins it."
  65)

(def- select-page
  (string "SELECT id, number, label FROM " seed/table
          " WHERE id >= $1 ORDER BY id LIMIT " page-size))

(defn- row-view [r]
  [:tr
   [:td {:class "id"} (r :id)]
   [:td {:class "number"} (r :number)]
   [:td {:class "label"} (r :label)]
   [:td {:class "actions"}
    [:a {:href (string "/rows/" (r :id))} "open"]
    " · "
    [:a {:href (string "/rows/" (r :id) "/edit")} "edit"]]])

(defn- document [rows]
  (html/html5
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "void bench — rows"]]
    [:body
     [:main
      [:h1 "rows"]
      [:table
       [:thead [:tr [:th "id"] [:th "number"] [:th "label"] [:th ""]]]
       [:tbody (map row-view rows)]]]]))

(defn rows
  "GET /rows — a page of rows, server-rendered."
  [req]
  # the listener opens in system/start and the seeding runs at
  # :after-start: until the table is full this page is short, and a
  # short page is a smaller document than the ~15KB budgeted. 503
  # rather than a quietly cheaper benchmark — runner/wait-ready waits
  # this out (targets :ready).
  (if (seed/seeded?)
    (let [from (inc (math/floor (* (math/random) (- seed/row-count page-size))))]
      (html/page (document (db/query-sql [select-page [from]])) {:layout nil}))
    (ring/response 503 "bench_rows is still being filled"
                   @{"content-type" "text/plain; charset=utf-8"
                     "retry-after" "1"})))

(plugin/contribute! :void.http/route-source
  {:name :bench.b3/routes
   :routes (router/routes {}
             (router/GET "/rows" 'rows {:name :rows}))
   :env (router/env-ref (curenv))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 900
   :name :bench.b3/seed
   :doc "Create and fill bench_rows if this database has not got it yet"
   :fn (fn seed! [_] (seed/ensure!))})

(plugin/defplugin bench/b3
  :doc "B3 Postgres + hiccup SSR — a query and 15KB of server-rendered HTML."
  :version "0.0.1"
  :requires {:void/http ">=0.0.1" :void/html ">=0.0.1"
             :void/db ">=0.0.1" :void/db-postgres ">=0.0.1"})

(def app
  {:plugins [;(if (= "0" (os/getenv "VOID_BENCH_PROBE")) [] [:bench/probe])
             :void/http :void/html :void/db :void/db-postgres :bench/b3]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") ""))
                                   8103)}
                  :db {:pool {:size 8}}
                  :db-postgres (pg/config)}}})

(defn main [& args]
  (void/run! app))
