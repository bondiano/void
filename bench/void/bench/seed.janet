### void/bench/seed — the one table B2 and B3 read (ROADMAP 2.5).
###
### Both database benchmarks read the same shape, on purpose: B3 minus
### B2 should be the cost of rendering, not the cost of a different
### query. `bench_rows` is the TechEmpower `world` table with a text
### column added, because a row that is nothing but two integers makes
### an SSR benchmark render integers.
###
### Creating and filling it is the app's own job at `:after-start`,
### idempotently — a benchmark whose setup is a README step is a
### benchmark that runs against a differently-shaped table on somebody
### else's machine, and CI would need a migration job to run two
### queries.

(import void/db :as db)

(def table "bench_rows")

(def row-count
  "How many rows the table holds. Ten thousand is TechEmpower's
  `world` size: large enough that a random single-row read is a real
  index lookup, small enough to sit in the buffer cache — this
  benchmark measures the driver and the pool, not the disk."
  10000)

(def labels
  "The label pool. Deterministic, so two machines seed the same bytes
  and an SSR payload is the same size everywhere."
  ["alpha" "bravo" "charlie" "delta" "echo" "foxtrot" "golf" "hotel"
   "india" "juliet" "kilo" "lima" "mike" "november" "oscar" "papa"])

(defn- label-for [i]
  (string (in labels (% i (length labels)))
          "-" (string/format "%05d" i)
          " lorem ipsum dolor sit amet consectetur"))

(defn ensure!
  ``Create `bench_rows` if it is not there and fill it if it is empty.
  Idempotent: a second boot against the same database does nothing but
  one count.``
  []
  (db/execute-sql
    (string "CREATE TABLE IF NOT EXISTS " table
            " (id int PRIMARY KEY, number int NOT NULL, label text NOT NULL)")
    []
    {:kind :write :prepared false})
  (def n (db/value {:select [[:raw "count(*) AS n"]] :from table}))
  (when (< (or n 0) row-count)
    (db/execute-sql (string "TRUNCATE " table) [] {:kind :write :prepared false})
    # one multi-row INSERT per thousand: ten statements instead of ten
    # thousand round trips, and small enough that no parameter limit is
    # anywhere near
    (var i 1)
    (while (<= i row-count)
      (def upto (min row-count (+ i 999)))
      (def values @[])
      (def params @[])
      (var p 1)
      (for k i (inc upto)
        (array/push values (string/format "($%d,$%d,$%d)" p (+ p 1) (+ p 2)))
        (+= p 3)
        (array/push params k)
        (array/push params (% (* k 7919) 10000))
        (array/push params (label-for k)))
      (db/execute-sql
        (string "INSERT INTO " table " (id, number, label) VALUES "
                (string/join values ","))
        params
        {:kind :write :prepared false})
      (set i (inc upto)))
    (printf "bench: seeded %s with %d rows" table row-count))
  row-count)
