### void/bench/pg — where B2 and B3 find a Postgres (ROADMAP 2.5).
###
### The database-backed benchmarks need a server, and rather than
### guess at one they ask for it by name — the same bargain the
### void/db-postgres suite makes:
###
###     VOID_BENCH_PG="host=127.0.0.1 port=5432 user=void dbname=void_bench" \
###       janet main.janet b2 b3
###
### `VOID_TEST_PG` is the fallback, so a machine (or a CI job) already
### set up to run the driver suite can run the benchmarks with nothing
### further. Without either, b2 and b3 are skipped loudly rather than
### run against an imaginary server: a benchmark that quietly measures
### nothing is worse than one that did not run.
###
### The conninfo goes into the `[:db-postgres]` slice as `:url` when it
### is a URL and as `:params` otherwise — the slice speaks keywords
### both ways (see void/db-postgres/config).

(def env-var
  "The variable the benchmarks read, in priority order."
  "VOID_BENCH_PG")

(def fallback-env-var
  "The driver suite's variable, used when the bench-specific one is
  unset."
  "VOID_TEST_PG")

(defn conninfo
  "The configured server, or nil."
  []
  (var out nil)
  (each v [env-var fallback-env-var]
    (when (nil? out)
      (when-let [s (os/getenv v)]
        (unless (empty? (string/trim s)) (set out (string/trim s))))))
  out)

(defn available?
  "Is there a server for B2/B3 to run against?"
  []
  (not (nil? (conninfo))))

(defn- keyword-params [info]
  (from-pairs
    (seq [pair :in (string/split " " info) :when (not (empty? pair))]
      (def i (string/find "=" pair))
      [(string/slice pair 0 i)
       # unquote a 'quoted value' — how a conninfo carries a password
       # with a space in it
       (let [v (string/slice pair (inc i))]
         (if (and (string/has-prefix? "'" v) (string/has-suffix? "'" v))
           (string/slice v 1 -2)
           v))])))

(defn config
  "The [:db-postgres] config slice for the configured server."
  [&opt extra]
  (def info (or (conninfo)
                (errorf "no Postgres configured — set %s (or %s)"
                        env-var fallback-env-var)))
  (merge (if (string/find "://" info)
           {:url info}
           {:params (keyword-params info)})
         {:application-name "void-bench"}
         (or extra {})))
