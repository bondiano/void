### B2 — Postgres single query (SPEC.md §8.2, ADR-0014).
### Budget: p50 < 3ms, p99 < 12ms, ≥ 3k RPS (1 worker, 1 vCPU).
###
### One indexed row per request, over the pool, through a prepared
### statement, on the ev loop — void/db-postgres driving libpq's
### non-blocking API through void/fdwait, with no thread pool anywhere
### (ADR-0011). The whole point of the row is what the number costs:
### B2 − B0 is the query, the pool checkout and the round trip, and
### nothing else, which is why the response is encoded by hand instead
### of going through void/rest (that pipeline is what B1 measures, and
### measuring it twice would hide the driver inside it).
###
### Needs a server: VOID_BENCH_PG (or VOID_TEST_PG). The table is
### created and seeded at :after-start, idempotently (see
### void/bench/seed). PORT overrides the listen port (default 8102).

(import ../prelude)
(import spork/json)
(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/db :as db)
(import void/bench/pg :as pg)
(import void/bench/seed :as seed)
(require "void/http/init")
(require "void/db/init")
(require "void/db-postgres/init")
(require "void/bench/probe")

(def- select-row
  (string "SELECT id, number, label FROM " seed/table " WHERE id = $1"))

(def- not-seeded
  # the listener opens in system/start and the seeding runs at
  # :after-start, so this window is real: a client can arrive while
  # bench_rows is still filling, and a random id in a half-filled
  # table hits about as often as it misses. Answering 200 (with a row,
  # or with a null body) there would let a warmup measure a table that
  # is not the benchmark's — 503 says what is true, and is what
  # runner/wait-ready waits out (targets :ready).
  (json/encode {:type "about:blank" :title "seeding"
                :status 503 :detail "bench_rows is still being filled"}))

(defn row
  "GET /db — one random row by primary key."
  [req]
  (if (seed/seeded?)
    (let [id (inc (math/floor (* (math/random) seed/row-count)))
          r (first (db/query-sql [select-row [id]]))]
      (ring/response 200 (json/encode r) @{"content-type" "application/json"}))
    (ring/response 503 not-seeded
                   @{"content-type" "application/problem+json"
                     "retry-after" "1"})))

(plugin/contribute! :void.http/route-source
  {:name :bench.b2/routes
   :routes (router/routes {}
             (router/GET "/db" 'row {:name :db}))
   :env (router/env-ref (curenv))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 900
   :name :bench.b2/seed
   :doc "Create and fill bench_rows if this database has not got it yet"
   :fn (fn seed! [_] (seed/ensure!))})

(plugin/defplugin bench/b2
  :doc "B2 Postgres single query — pool, prepared statement, ev loop."
  :version "0.0.1"
  :requires {:void/http ">=0.0.1" :void/db ">=0.0.1"
             :void/db-postgres ">=0.0.1"})

(def app
  {:plugins [;(if (= "0" (os/getenv "VOID_BENCH_PROBE")) [] [:bench/probe])
             :void/http :void/db :void/db-postgres :bench/b2]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") ""))
                                   8102)}
                  # one worker, one vCPU (§8.2) — a pool bigger than a
                  # handful of connections would only queue in Postgres
                  # instead of queueing here
                  :db {:pool {:size 8}}
                  :db-postgres (pg/config)}}})

(defn main [& args]
  (void/run! app))
