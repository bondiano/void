### Refuse a second copy of what wave 8.3 made one of.
###
### Every mechanism below used to be written more than once — a fiber
### pool in db and in redis, a lease table in jobs-db and in bus-db,
### the late-binding resolver in the router, in jobs and in bus, the
### chunked-body reader in the http server and in the http client,
### `callable?` twenty-five times — and every copy drifted from the
### others in a way nobody saw until the review that produced wave 8.
### The wave's exit criterion is that none is written twice again, and
### a criterion that is a grep in a commit body is one the next wave
### forgets; so the greps live here, as data, and CI runs them the way
### it runs gen-contracts:
###
###     janet scripts/check-copies.janet
###
### Each entry names the mechanism, the text that gives a copy away,
### the files allowed to carry that text (the one implementation, plus
### the call sites a commit body has argued for) and why. A hit outside
### the allowlist is printed as file:line and fails the run. The
### package directories come from scripts/packages.janet — a package
### added to the graph is walked here without touching this file — and
### only the `void/` source trees are searched; a pattern that also
### wants a package's test and test-support directories says `:tests`.
###
### This file is not walked (scripts/ is not a package), which is what
### lets it spell the patterns out without tripping on itself.

(import ./packages :as packages)

# -- the copies ----------------------------------------------------------
#
# Per entry:
#
#   :name      the mechanism, as the report prints it
#   :pattern   a PEG; a match anywhere in a file is a hit
#   :allow     repo-relative files whose hits are the implementation
#              or an argued exception — every other hit fails
#   :why       why those files and no other
#   :only      (optional) restrict the walk to these packages
#   :basename  (optional) restrict the walk to files with this name
#   :tests     (optional) walk <pkg>/test and <pkg>/test-support too

(def copies
  [{:name "helper copies (callable?, names-str, unique-by, suggest, levenshtein, err-str)"
    :pattern ~(* "(defn" (? "-") " "
                 (+ "callable?" "names-str" "unique-by" "suggest" "levenshtein" "err-str")
                 (set " \n"))
    :allow ["core/void/core/util.janet"
            "kafka/void/kafka/librdkafka.janet"
            "jobs/void/jobs/worker.janet"]
    :why "void/core/util is the one home (65694c1, 6430556). kafka's err-str is rd_kafka_err2str and jobs's is log/message-of for the job record — the same name for a different function, not a copy of util's."}

   {:name "names-str spelled inline"
    :pattern ~(* "string/format \"%q\" $) (sorted")
    :allow ["core/void/core/util.janet"]
    :why "the 28 inline `(string/join (map |(string/format \"%q\" $) (sorted …)) \" \")` became util/names-str (b4ca04e)."}

   {:name "callable? spelled inline"
    :pattern ~(* "(or (function? " (some (range "az")) ") (cfunction? " (some (range "az")) "))")
    :allow ["core/void/core/util.janet"
            "cli/void/cli/lock.janet"]
    :why "util/callable? is the check; cli/lock's is a cond clause of rendering code that keeps its own shape (65694c1)."}

   {:name "a task under a deadline (ev/deadline, ev/with-deadline)"
    :pattern ~(* "(ev/" (? "with-") "deadline ")
    :allow ["core/void/core/deadline.janet"
            "core/void/core/system.janet"
            "bench/void/bench/runner.janet"
            "cli/void/cli/doctor.janet"
            "ws/void/ws/client.janet"]
    :why "core/deadline is the implementation; the four call sites are one-shot waits on a fiber that is not long-lived (a benchmark's os/proc-wait, doctor's net/connect probe, a websocket close drain, a component's :stop under the shutdown's own timeout — b4ca04e names them)."}

   {:name "a fiber pool (waiters queue, acquire)"
    :pattern ~(+ ":waiters @["
                 (* "(defn" (? "-") " "
                    (+ "acquire" "live-waiters" "take-idle" "wait-for-wake-up" "next-waiter" "wake-one")
                    (set " \n")))
    :allow ["core/void/core/pool.janet"]
    :why "void/core/pool is the one pool; db/pool and redis/pool are adapters that pass :connect/:close/:validate/:reusable? and keep no queue of their own (e0a179c)."}

   {:name "a lease table as a DDL string"
    :pattern ~(* "CREATE TABLE")
    :only [:void/jobs :void/bus]
    :allow []
    :why "jobs-db and bus-db take their lease from void/db/lease, whose table is a builder statement compiled per dialect; a DDL string in either plugin is the copy 9398f8b removed."}

   {:name "late-binding resolution (a second resolver, or the refusal it replaced)"
    :pattern ~(+ "no longer names a function"
                 "does not resolve to a function"
                 "not wired"
                 "resolve-binding"
                 "resolve-callable"
                 "resolve-handler")
    :allow ["core/void/core/bind.janet"]
    :why "void/core/bind resolves a symbol for the router, jobs, bus, mcp and cli alike, and owns the sentences; the router's three resolve-* helpers are gone (cb8642f)."}

   {:name "a chunked-body reader"
    :pattern ~(* "(defn" (? "-") " " (+ "read-chunked" "decode-chunked" "parse-chunk-head"))
    :allow ["http/void/http/wire.janet"]
    :why "wire owns the decoder and the reader that drives it; server and client call wire/read-chunked with their own I/O (ad37399)."}

   {:name "a socket error classified by a substring of its message"
    :pattern ~(* "string/find \"" (+ "closed" "reset" "broken" "pipe" "timeout" "deadline") "\"")
    :allow ["http/void/http/wire.janet"]
    :why "wire/net-error-kind maps the exact texts janet's net raises, macOS and Linux spellings both; a `(string/find \"closed\" …)` elsewhere is the list ad37399 replaced."}

   {:name "one-contribution-per-name written by hand in an extension point"
    :pattern ~(+ "(put seen " "util/unique-by")
    :basename "init.janet"
    :allow ["mcp/void/mcp/init.janet"]
    :why "a point says :key and the kernel checks and folds; :void.mcp/resource is unique by an optional :uri, the one check the option cannot express (8c99c67)."}

   {:name "a live-service gate written by hand"
    :pattern ~(+ "unless (empty? (string/trim v)) (string/trim v)"
                 "SKIPPED (set ")
    :tests true
    :allow ["dev/void/test.janet"
            "dev/test/test-test.janet"
            "bench/test/apps-test.janet"]
    :why "test/service in void/dev is the gate (65694c1); its own suite asserts the line it prints, and bench's b2/b3 smoke gates on either of two variables, which the one-variable gate cannot say."}])

# -- the walk ------------------------------------------------------------

(def skipped-dirs
  "Directory names never descended into, wherever they appear."
  {"jpm_tree" true ".void-tree" true ".git" true "build" true})

(defn- janet-files
  "Every *.janet under `dir` (absolute), depth first, sorted."
  [dir]
  (def out @[])
  (defn walk [d]
    (each f (sorted (os/dir d))
      (def path (string d "/" f))
      (case (os/stat path :mode)
        :directory (unless (skipped-dirs f) (walk path))
        :file (when (string/has-suffix? ".janet" f) (array/push out path)))))
  (when (= :directory (os/stat dir :mode)) (walk dir))
  out)

(defn- relative
  "A path under the repository root, repo-relative."
  [path]
  (string/slice path (inc (length packages/root))))

(defn- package-files
  ``The files an entry walks: the `void/` tree of each package in its
  scope, and its test directories when the entry asks for them.``
  [entry]
  (def names (or (entry :only) (packages/packages)))
  (def subdirs (if (entry :tests) ["void" "test" "test-support"] ["void"]))
  (def files
    (mapcat |(mapcat (fn [sub] (janet-files (string (packages/dir $) "/" sub)))
                     subdirs)
            names))
  (if-let [base (entry :basename)]
    (filter |(string/has-suffix? (string "/" base) $) files)
    files))

(defn- line-of
  "1-based line number of byte offset `pos` in `text`."
  [text pos]
  (inc (length (string/find-all "\n" (string/slice text 0 pos)))))

(defn- line-text
  "The line containing byte offset `pos`, trimmed."
  [text pos]
  (def start (if-let [nl (last (string/find-all "\n" (string/slice text 0 pos)))] (inc nl) 0))
  (def stop (or (string/find "\n" text pos) (length text)))
  (string/trim (string/slice text start stop)))

(defn- hits-in
  "Every match of `entry`'s pattern in `path` outside the allowlist, as {:file :line :text}."
  [entry path]
  (def rel (relative path))
  (if (index-of rel (entry :allow))
    []
    (let [text (slurp path)]
      (seq [pos :in (peg/find-all (entry :pattern) text)]
        {:file rel :line (line-of text pos) :text (line-text text pos)}))))

(defn check
  "Every hit of every entry outside its allowlist, in table order."
  []
  (seq [entry :in copies
        path :in (package-files entry)
        hit :in (hits-in entry path)]
    (merge hit {:name (entry :name)})))

(defn main [&]
  (def hits (check))
  (unless (empty? hits)
    (var current nil)
    (each h hits
      (unless (= current (h :name))
        (set current (h :name))
        (eprintf "%s:" current))
      (eprintf "  %s:%d: %s" (h :file) (h :line) (h :text)))
    (errorf "copies: %d hit(s) outside the allowlists — one implementation each, see the table in scripts/check-copies.janet"
            (length hits)))
  (printf "no copies (%d patterns over %d packages)"
          (length copies) (length (packages/packages))))
