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
###     janet scripts/check-copies.janet              # the gate
###     janet scripts/check-copies.janet --self-test  # the patterns
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
### A gate is only as good as its patterns, and a pattern that stops
### matching anything makes the gate green forever. Two controls keep
### it honest. The run itself checks every allowed file still matches
### (an allowlist entry nothing matches is a renamed implementation or
### dead text, and fails the run either way); and `--self-test` plants
### each entry's `:samples` — the copies someone could write tomorrow,
### spelled with the other identifier, the other order, a line break —
### into a string and asserts a hit, so a widening a later edit undoes
### is red before a copy is written.
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
#   :allow     repo-relative files whose hits are the implementation or
#              an argued exception — every other hit fails. An item is
#              a file (every hit in it is allowed) or `[file text]` (a
#              hit in that file is allowed only when the line it is on
#              contains `text` — a file argued for one name is not
#              thereby allowed the others). Every item must match at
#              least once, or the run fails.
#   :no-implementation
#              true for an entry whose pattern is the copy's own text
#              and never the implementation's — so an empty :allow is
#              the honest allowlist, not a forgotten one
#   :why       why those files and no other
#   :samples   texts the pattern must find (--self-test)
#   :not       texts it must not (--self-test)
#   :only      (optional) restrict the walk to these packages
#   :tests     (optional) walk <pkg>/test and <pkg>/test-support too

(def- ident
  "A janet identifier, as a PEG."
  ~(some (+ (range "az" "AZ" "09") (set "-?!*/_<>=+.$%&^@:"))))

(def- form
  "An identifier or a parenthesised form with balanced parens — what
  the argument of a predicate call looks like."
  ~{:main (+ ,ident (* "(" (any (+ :main :s+)) ")"))})

(defn- defn-of
  "A `defn` or `defn-` of one of `names`, and nothing that merely
  starts with one (`suggest` is not `suggest-fix`)."
  [& names]
  ~(* "(defn" (? "-") :s+ (+ ,;names) :s))

(def- socket-texts
  ``The heads of the texts http/wire's `net-error-texts` classifies
  (the exact spellings janet's net and the two OSes raise), and the
  bare words a copy would test for. A `string/find` on any of them is
  a socket error classified by a substring of its message.``
  ["Operation timed" "Connection timed" "Connection reset" "Broken pipe"
   "Software caused" "stream closed" "stream err" "stream is closed"
   "Bad file" "Socket is not" "parent canceled" "sibling canceled"
   "closed\"" "reset\"" "broken\"" "pipe\"" "timeout\"" "deadline\""])

(def copies
  [{:name "helper copies (callable?, names-str, unique-by, suggest, levenshtein, err-str)"
    :pattern (defn-of "callable?" "names-str" "unique-by" "suggest" "levenshtein" "err-str")
    :allow ["core/void/core/util.janet"
            ["kafka/void/kafka/librdkafka.janet" "err-str"]
            ["jobs/void/jobs/worker.janet" "err-str"]]
    :why "void/core/util is the one home (65694c1, 6430556). kafka's err-str is rd_kafka_err2str and jobs's is log/message-of for the job record — the same name for a different function, not a copy of util's; neither file is thereby allowed the other five names."
    :samples ["(defn- callable? [x] ...)" "(defn callable?\n  [x]" "(defn err-str\n  [e]"]
    :not ["(def callable? (fn [x] ...))" "(defn suggest-fix [x]"]}

   {:name "names-str spelled inline"
    :pattern ~(* "string/format \"%q\" $) (sorted")
    :allow ["core/void/core/util.janet"]
    :why "the 28 inline `(string/join (map |(string/format \"%q\" $) (sorted …)) \" \")` became util/names-str (b4ca04e)."
    :samples ["(string/join (map |(string/format \"%q\" $) (sorted names)) \" \")"]}

   {:name "callable? spelled inline"
    :pattern ~{:fn (* "(function?" :s+ ,form :s* ")")
               :cfn (* "(cfunction?" :s+ ,form :s* ")")
               :main (* "(or" :s+ (+ (* :fn :s+ :cfn) (* :cfn :s+ :fn)) :s* ")")}
    :allow ["core/void/core/util.janet"
            "cli/void/cli/lock.janet"]
    :why "util/callable? is the check; cli/lock's is a cond clause of rendering code that keeps its own shape (65694c1)."
    :samples ["(or (function? f) (cfunction? f))"
              "(or (function? f1) (cfunction? f1))"
              "(or (function? handler-fn) (cfunction? handler-fn))"
              "(or (cfunction? f) (function? f))"
              "(or (function? f)\n    (cfunction? f))"
              "(or (function? (h :fn)) (cfunction? (h :fn)))"]
    :not ["(or (function? f) (nil? f))"]}

   {:name "a task under a deadline (ev/deadline, ev/with-deadline)"
    :pattern ~(* "(ev/" (? "with-") "deadline" :s+)
    :allow ["core/void/core/deadline.janet"
            "core/void/core/system.janet"
            "bench/void/bench/runner.janet"
            "cli/void/cli/doctor.janet"
            "ws/void/ws/client.janet"]
    :why "core/deadline is the implementation; the four call sites are one-shot waits on a fiber that is not long-lived (a benchmark's os/proc-wait, doctor's net/connect probe, a websocket close drain, a component's :stop under the shutdown's own timeout — b4ca04e names them)."
    :samples ["(ev/deadline 5 nil f)" "(ev/with-deadline 5\n  (ev/take ch))" "(ev/deadline\n 5 nil f)"]
    :not ["(deadline/run 5 f)"]}

   {:name "a fiber pool (waiters queue, acquire)"
    :pattern ~(+ ":waiters @["
                 ,(defn-of "acquire" "live-waiters" "take-idle" "wait-for-wake-up" "next-waiter" "wake-one"))
    :allow ["core/void/core/pool.janet"]
    :why "void/core/pool is the one pool; db/pool and redis/pool are adapters that pass :connect/:close/:validate/:reusable? and keep no queue of their own (e0a179c)."
    :samples [":waiters @[]" "(defn- acquire\n  [pool]" "(defn wake-one [pool]"]
    :not ["(defn acquire-lock [k]"]}

   {:name "a lease table as a DDL string"
    :pattern ~(* "CREATE TABLE")
    :only [:void/jobs :void/bus]
    :allow []
    :no-implementation true
    :why "jobs-db and bus-db take their lease from void/db/lease, whose table is a builder statement compiled per dialect; a DDL string in either plugin is the copy 9398f8b removed."
    :samples ["\"CREATE TABLE IF NOT EXISTS void_jobs_leases (\""]}

   {:name "late-binding resolution (a second resolver, or the refusal it replaced)"
    :pattern ~(+ "no longer names a function"
                 "does not resolve to a function"
                 "not wired"
                 "resolve-binding"
                 "resolve-callable"
                 "resolve-handler")
    :allow ["core/void/core/bind.janet"]
    :why "void/core/bind resolves a symbol for the router, jobs, bus, mcp and cli alike, and owns the sentences; the router's three resolve-* helpers are gone (cb8642f)."
    :samples ["(defn- resolve-handler [sym env]" "(errorf \"%s does not resolve to a function\" sym)"]}

   {:name "a chunked-body reader"
    :pattern (defn-of "read-chunked" "decode-chunked" "parse-chunk-head")
    :allow ["http/void/http/wire.janet"]
    :why "wire owns the decoder and the reader that drives it; server and client call wire/read-chunked with their own I/O (ad37399)."
    :samples ["(defn- read-chunked\n  [stream]" "(defn parse-chunk-head [line]"]}

   {:name "a socket error classified by a substring of its message"
    :pattern ~(* "string/" (+ "find" "has-prefix?" "has-suffix?") :s+ "\"" (+ ,;socket-texts))
    :allow []
    :no-implementation true
    :why "wire/net-error-kind maps the exact texts janet's net raises through a table — the texts above are the heads of its lists — so the implementation never spells a substring test; a `(string/find \"closed\" …)` anywhere is the list ad37399 replaced."
    :samples ["(string/find \"closed\" msg)"
              "(string/find \"Connection reset\" msg)"
              "(string/has-suffix? \"closed\" msg)"
              "|(string/find \"Broken pipe\" $)"]
    :not ["(string/find \"closed-at\" line)"]}

   {:name "one-contribution-per-name written by hand in an extension point"
    :pattern ~(+ (* ":validate" :s+ "(fn" :s+ "[" ,ident "]" :s+ "(def" :s+ ,ident :s+ "@{})")
                 "util/unique-by"
                 (* "(errorf" :s+ "\"duplicate "))
    :allow ["core/void/core/util.janet"
            "core/void/core/extension.janet"
            "mcp/void/mcp/init.janet"
            ["redis/void/redis/init.janet" "duplicate redis codec"]
            ["core/void/core/system.janet" "duplicate component"]]
    :why "a point says :key and the kernel checks (through util/unique-by, whose sentence is the one) and folds; :void.mcp/resource is unique by an optional :uri, and :void.redis/codec lists every repeated name in one sentence — the two checks the option cannot express (8c99c67); system's is the component-key check of a boot, not a point."
    :samples [":validate (fn [contribs]\n              (def seen @{})"
              ":validate (fn [cs] (def names @{})"
              "(util/unique-by \"middleware name\" |($ :name))"
              "(errorf \"duplicate %s %q\" what (c :name))"]
    :not [":validate (fn [cs] (each c cs (check c)))"]}

   {:name "a live-service gate written by hand"
    :pattern ~(+ "unless (empty? (string/trim v)) (string/trim v)"
                 "SKIPPED (set ")
    :tests true
    :allow ["dev/void/test.janet"
            "dev/test/test-test.janet"
            "bench/test/apps-test.janet"]
    :why "test/service in void/dev is the gate (65694c1); its own suite asserts the line it prints, and bench's b2/b3 smoke gates on either of two variables, which the one-variable gate cannot say."
    :samples ["(printf \"%s: SKIPPED (set %s to a url)\" suite var)"]}])

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
  (mapcat |(mapcat (fn [sub] (janet-files (string (packages/dir $) "/" sub)))
                   subdirs)
          names))

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

(defn- allow-file
  "The file an allowlist item names."
  [item]
  (if (string? item) item (item 0)))

(defn- allows?
  "Does allowlist `item` cover a hit in `file` on the line `text`? A
  bare file covers every hit in it; `[file name]` only a hit whose
  line contains `name`."
  [item file text]
  (and (= file (allow-file item))
       (or (string? item) (truthy? (string/find (item 1) text)))))

(defn- matches-in
  "Every match of `entry`'s pattern in `path`, as {:file :line :text}
  — the line both for the report and for the per-name allowlist."
  [entry path]
  (def rel (relative path))
  (def text (slurp path))
  (seq [pos :in (peg/find-all (entry :pattern) text)]
    {:file rel :line (line-of text pos) :text (line-text text pos)}))

(defn- check-entry
  ``One entry over its files: `:hits` are the matches no allowlist item
  covers, `:dead` the allowlist items nothing matched — an
  implementation that moved or was renamed, or text the table should
  no longer carry.``
  [entry]
  (def found (mapcat |(matches-in entry $) (package-files entry)))
  (def allow (entry :allow))
  (defn covered-by [m] (find |(allows? $ (m :file) (m :text)) allow))
  {:name (entry :name)
   :hits (filter |(nil? (covered-by $)) found)
   :dead (filter (fn [item] (not (some |(allows? item ($ :file) ($ :text)) found)))
                 allow)})

(defn check
  "Every entry's uncovered hits and dead allowlist items, in table order."
  []
  (map check-entry copies))

(defn- report
  "Print one entry's findings to stderr; how many things are wrong."
  [{:name name :hits hits :dead dead}]
  (unless (and (empty? hits) (empty? dead))
    (eprintf "%s:" name)
    (each h hits
      (eprintf "  %s:%d: %s" (h :file) (h :line) (h :text)))
    (each item dead
      (eprintf "  %s: allowed but never matched (%s)"
               (allow-file item)
               (if (string? item) "an implementation that moved, or dead text" (string "for " (string/format "%q" (item 1)))))))
  (+ (length hits) (length dead)))

# -- the self-test: every pattern still finds the copy it is for --------

(defn- entry-declares-a-home?
  "Every entry either allows the implementation or says there is none."
  [entry]
  (or (not (empty? (entry :allow))) (= true (entry :no-implementation))))

(defn self-test
  ``Plant each entry's `:samples` into a string and assert the pattern
  finds them, and that its `:not` texts stay unfound; refuse an entry
  with neither an allowlist nor `:no-implementation`. Returns the
  failures as strings.``
  []
  (def failures @[])
  (each e copies
    (unless (entry-declares-a-home? e)
      (array/push failures (string/format "%s: an empty :allow needs :no-implementation true" (e :name))))
    (when (empty? (get e :samples []))
      (array/push failures (string/format "%s: no :samples — a pattern nothing exercises" (e :name))))
    (each s (get e :samples [])
      (unless (peg/find (e :pattern) (string "(def x 1)\n" s "\n(def y 2)\n"))
        (array/push failures (string/format "%s: does not find %q" (e :name) s))))
    (each s (get e :not [])
      (when (peg/find (e :pattern) s)
        (array/push failures (string/format "%s: finds %q, which it should not" (e :name) s)))))
  failures)

(defn main [& args]
  (if (index-of "--self-test" args)
    (let [failures (self-test)]
      (each f failures (eprint f))
      (unless (empty? failures)
        (errorf "check-copies self-test: %d pattern(s) do not find what they are for" (length failures)))
      (printf "patterns ok (%d patterns, %d samples)"
              (length copies) (sum (map |(length (get $ :samples [])) copies))))
    (let [wrong (sum (map report (check)))]
      (unless (zero? wrong)
        (errorf "copies: %d problem(s) — one implementation each, see the table in scripts/check-copies.janet"
                wrong))
      (printf "no copies (%d patterns over %d packages)"
              (length copies) (length (packages/packages))))))
