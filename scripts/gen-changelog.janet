### Generate CHANGELOG.md from the git history — a projection, not prose.
###
### The history is already the changelog: every commit here is written
### as `type: subject`, one commit per landed piece,
### and the tags v0.1..v0.4 mark the wave boundaries. So the changelog
### is not a second document somebody keeps in sync — it is this
### script's output, grouped by release and by type, with every
### ADR-nnnn mention turned into a link to the decision it names. The
### same reasoning as CONTRACTS.md and the docs site: no page written
### by hand stays true.
###
### Run from the repository root:
###
###     janet scripts/gen-changelog.janet         # -> CHANGELOG.md
###     janet scripts/gen-changelog.janet check   # CI gate, writes nothing
###
### Commits after the newest tag land in an «Unreleased» section, so
### the file is regenerated at release time (tag first, generate
### second) and may be regenerated any day in between to preview.
###
### `check` is the same gate CONTRACTS.md has: the *released* part of
### the file must equal what the history projects — a tag without a
### regenerated changelog fails CI. The Unreleased section is left out
### of the comparison on purpose: it contains the commit being checked,
### which cannot have known its own hash. And the newest tag must not
### be ahead of void/core's `version`, since that is the one place the
### version is written and everything else reads it.

(import ../core/void/core/init :as core)

(defn- git
  "Run one git command, return its trimmed stdout."
  [& args]
  (with [p (os/spawn ["git" ;args] :px {:out :pipe})]
    (def out (ev/read (p :out) :all))
    (:wait p)
    (string/trim (string out))))

# -- what the repository says about itself -------------------------------

(defn- ancestor?
  "Is this ref an ancestor of HEAD — that is, does the history this
  repository has now actually contain it?"
  [ref]
  (def devnull (file/open "/dev/null" :w))
  (defer (file/close devnull)
    (zero? (os/execute ["git" "merge-base" "--is-ancestor" (string ref "^{commit}") "HEAD"]
                       :p {:out devnull :err devnull}))))

(var- skipped
  "Tags that name commits this history does not contain — reported at
  the end, never silently dropped."
  @[])

(defn- tags
  ``Release tags, oldest first — vX.Y sorted numerically, and **only
  those the current history contains**.

  A tag that is not an ancestor of HEAD names a commit that was
  rewritten away (this repository's own history was rebuilt once, and
  v0.3/v0.4 were left pointing into what it used to be). Such a tag
  cannot be a boundary of anything: the range `v0.4..v0.5` would be the
  whole history, and every earlier section would describe commits that
  are no longer here. Rather than project that, the tag is skipped and
  said out loud — a changelog with a release nobody can `git show` is
  worse than a changelog with one fewer heading.``
  []
  (def all (filter |(peg/match ~(* "v" :d+ "." :d+ -1) $)
                   (string/split "\n" (git "tag"))))
  (def live (filter ancestor? all))
  (array/clear skipped)
  (each t all (unless (index-of t live) (array/push skipped t)))
  (sorted live (fn [a b]
                 (def [amaj amin] (map scan-number (string/split "." (string/slice a 1))))
                 (def [bmaj bmin] (map scan-number (string/split "." (string/slice b 1))))
                 (or (< amaj bmaj) (and (= amaj bmaj) (< amin bmin))))))

(defn- tag-date [tag]
  (git "log" "-1" "--format=%as" tag))

(def- subjects-en
  ``The English of the subjects of a stretch of history that was
  written in Russian. Keyed by hash, so the file stays a projection —
  the entries are labels for commits that already exist, never a place
  to say something the commit does not.``
  {"d32eeaa" "feat: the service pages — an operator's dark theme, and the real reason they looked broken: the dash and admin asset routes answered with an immutable struct, so the CSRF middleware could not add its cookie header and the stylesheet 500'd in any composition with void/security"
   "e60d751" "fix: false \"server is under pressure\" 503s — both causes were in the scheduler: a connection fiber that never parks starves the timers, and the sampler recorded the whole busy period as loop lag; a yield budget and a heartbeat stamp fix both"
   "0b6b9b1" "fix: the password is hashed outside the transaction — the register routes in shop and blog drop :void.db/txn, because a KDF under BEGIN IMMEDIATE holds sqlite's single writer"
   "162d8d1" "feat: void/dash in the shop composition — the dashboard over the forty plugins of a real application; :plugins-for reads its three environment switches at call time"
   "41cb70d" "fix: sqlite waits cooperatively — the busy-wait moved out of the C call, where it blocked the whole ev loop, into the driver: retry plus ev/sleep within the same busy timeout"
   "b72b692" "fix: :plugins-for — a composition as a function of the profile becomes an explicit boot-option contract; run! and every CLI command resolve it, and guessing the plugins binding out of main by name is gone"
   "922fc35" "docs: the roadmap for wave 7, and the idea-to-deploy walkthrough checked against the nine files the template writes"
   "c77154d" "docs: the site — Getting Started with output taken from a real run, an API reference over 39 packages projected from manifests and docstrings, a cookbook off the examples, and an honest comparison page"
   "10ec63e" "feat: a start without friction — void new writes a dev compose file, a smoke suite and a prod profile; void doctor names what the machine is missing, in sentences and in an exit code; void services prints compose rather than editing it"
   "e9d369b" "feat: pressure knows about the pool — a built-in :void.pressure/check for an exhausted :db/pool (a waiter threshold with a grace period up to the checkout timeout), and a test of the obs pool gauges against a live pool"
   "82f8c06" "feat: void/dash — the dev dashboard as a fourth projection: six reader pages over plugin/inspect, config/explain, boot and the route table, a ring sink of logs with a live tail, and history with sparklines"
   "fd277a5" "fix: the site and the registries — tables and links inside emphasis finally render (with a smoke test in the generator), the site builds in CI, and gen-contracts became a projection of packages.janet"
   "51e33fe" "fix: admin/MCP — the list tool reads :list rather than :detail (the examples' password hashes stop reaching an agent), nil from :scope means nothing, resource declarations go through the same ensure!, and a secret column warns"
   "0499b6b" "fix: the security layer — introspection without aud/iss is refused (the confused deputy is closed on both branches), and the webhook channel neither reaches private ranges nor carries configured headers to somebody else's URL"
   "597ff08" "fix: the kernel cleans up after itself — a late start! failure stops the system, component data schemas are validated, a failed restart is retried by the watcher; netrepl only outside :prod, with a 0700 socket"
   "095ff8e" "fix: the response cache moves inside authz (phase 5500) and steps aside for a Cookie (opt-in :vary-cookie false), single-flight survives recursion; storage — SigV4 encodes the path exactly once"
   "7c20ee0" "fix: redis — a scanner/grammar disagreement no longer poisons the pool (parse under protect plus mark-broken), an unclean connection (MULTI/WATCH/pending) is closed on checkin"
   "6251bb8" "fix: the queue — token fencing for settle!/touch! on every backend, a SAVEPOINT around the unique insert, _locks cleanup and honest docstrings for the cron guarantees"
   "fd6d26d" "fix: a connection abandoned mid-protocol no longer returns to the pool — :reusable? on the driver, a cancellation-proof handoff of waiters, db/detached for ev/go, and drained collect/stream"
   "0873b48" "fix: HTTP wire hygiene — CRLF in outgoing headers, the empty chunk, a strict Content-Length, query with [ ] and UTF-8, Secure on the session cookie, deadlines against slowloris, Origin on WS"
   "4eff2c1" "chore: LICENSE (MIT) and SECURITY.md — a repository that can be used, and told about a vulnerability"
   "7031e6b" "chore: the changelog for v0.5 — and a tag the history does not contain stops pretending to be a boundary"
   "6736d4b" "docs: README v0.5 — waves 0-6 closed, the application deployed"})

(defn- commits
  "Commits of one range as {:hash :subject}, newest first; merge
  commits are skipped (there are none, but a projection should not
  depend on that)."
  [range]
  (def raw (git "log" "--no-merges" "--format=%h%x09%s" range))
  (if (empty? raw)
    @[]
    (seq [line :in (string/split "\n" raw)
          :let [[hash subject] (string/split "\t" line 0 2)]]
      {:hash hash :subject (get subjects-en hash subject)})))

(defn- strip-refs
  ``A commit subject as the changelog prints it. Older subjects carry
  a "(wave N, ADR-nnnn)" tail from when the design record lived in the
  repository; the record does not any more, so the pointer goes and
  the sentence stays.``
  [subject]
  (def cleaned
    (peg/replace-all
      ~(* "(" (any (if-not (set "()") 1)) "ADR-" (repeat 4 :d)
          (any (if-not (set "()") 1)) ")")
      ""
      subject))
  (def once (peg/replace-all ~(* "ADR-" (repeat 4 :d)) "" (string cleaned)))
  (string/trimr (peg/replace-all ~(some " ") " " (string once)) " ,;"))

# -- rendering -----------------------------------------------------------

(def- sections
  "Commit type -> changelog section, in print order."
  [["feat" "Added"]
   ["fix" "Fixed"]
   ["perf" "Performance"]
   ["docs" "Documentation"]
   [nil "Other"]])    # chore/refactor/test/style/revert and anything else

(def- known-types (map first (filter first sections)))

(defn- split-subject
  "\"feat: void/tls — ...\" -> [\"feat\" \"void/tls — ...\"]; a subject
  without a known prefix goes to \"Other\" whole."
  [subject]
  (if-let [colon (string/find ": " subject)]
    (let [t (string/slice subject 0 colon)]
      (if (index-of t known-types)
        [t (string/slice subject (+ colon 2))]
        [nil subject]))
    [nil subject]))

(def- release-themes
  ``One line per release checkpoint. A drift here is a wrong label,
  not a wrong history.``
  {"v0.1" "end of wave 1 — HTMX applications can be built on it, and there is something to show; the Plugin API and Route Metadata contracts are frozen"
   "v0.2" "end of wave 2 — the product minimum, core parity with Laravel"
   "v0.3" "end of wave 3 — the enterprise vertical: obs / auth / authz / bus"
   "v0.4" "end of wave 4 — the killer features: admin + MCP"
   "v0.5" "end of wave 6 — parity and the first application: storage, the auth scaffold, the jobs dashboard, notifications, tailwind without node, htmx 4 — and examples/hub, deployed"})

(defn- render-release [buf title date theme cs]
  (buffer/push buf "## " title)
  (when date (buffer/push buf " — " date))
  (buffer/push buf "\n\n")
  (when theme (buffer/push buf theme "\n\n"))
  (if (empty? cs)
    (buffer/push buf "*(no commits)*\n\n")
    (do
      (def grouped @{})
      (each c cs
        (def [t rest] (split-subject (c :subject)))
        (def bucket (or (get grouped t) (let [a @[]] (put grouped t a) a)))
        (array/push bucket {:hash (c :hash) :text rest}))
      (each [t header] sections
        (when-let [items (get grouped t)]
          (buffer/push buf "### " header "\n\n")
          (each item items
            (buffer/push buf "- " (strip-refs (item :text))
                         " (`" (item :hash) "`)\n"))
          (buffer/push buf "\n"))))))

(defn- render
  "The whole file as a string, projected from the history now."
  []
  (def ts (tags))
  (when (empty? ts)
    (error "no release tags — nothing to project"))
  (def buf @"")
  (buffer/push buf
    "# Changelog\n\n"
    "> A projection of the git history (`scripts/gen-changelog.janet`), "
    "not a manuscript: every commit in this repository is already named "
    "`type: what`, and the tags mark the release boundaries. The file is "
    "regenerated at a release; it is not edited by hand — the edit goes "
    "where it was projected from.\n\n")
  # the same sentence the script prints to stderr, put where a reader
  # of the file is: a heading that is missing needs to say so, or the
  # next person goes looking for a bug in the projection
  (unless (empty? skipped)
    (buffer/push buf
      "> " (string/join skipped " and ") " are missing here: the repository "
      "once rebuilt its history, and those tags still point at commits it "
      "no longer contains. A tag the history does not hold cannot be a "
      "boundary, so the release below covers everything that accumulated "
      "since the previous *live* tag.\n\n"))
  # unreleased first, newest release next
  (def newest (last ts))
  (def pending (commits (string newest "..HEAD")))
  (unless (empty? pending)
    (render-release buf "Unreleased" nil
                    (string "after " newest "")
                    pending))
  (loop [i :down-to [(dec (length ts)) 0]]
    (def tag (in ts i))
    (def range (if (zero? i) tag (string (in ts (dec i)) ".." tag)))
    (render-release buf tag (tag-date tag) (get release-themes tag)
                    (commits range)))
  {:text (string (string/trimr buf "\n") "\n")
   :tags ts
   :pending pending})

(defn- released-part
  "Everything from the first release heading on — the part of the file
  that is a function of tagged history alone."
  [text]
  (if-let [at (string/find "\n## v" text)]
    (string/slice text (inc at))
    text))

(defn- tag<?
  "vX.Y[.Z] numeric order."
  [a b]
  (defn parts [t] (map scan-number (string/split "." (string/slice t 1))))
  (def [pa pb] [(parts a) (parts b)])
  (var result nil)
  (loop [i :range [0 (max (length pa) (length pb))] :until (not (nil? result))]
    (def [x y] [(get pa i 0) (get pb i 0)])
    (cond (< x y) (set result true)
          (> x y) (set result false)))
  (or result false))

(defn- check
  "Exit 1 with a sentence when the file on disk or the version in
  void/core has fallen behind the tags."
  []
  (def {:text text :tags ts} (render))
  (def newest (last ts))
  (var failed false)
  (when (tag<? core/release-tag newest)
    (set failed true)
    (eprintf (string "void/core says version %s (tag %s), but the history "
                     "is already tagged %s — bump `version` in "
                     "core/void/core/init.janet")
             core/version core/release-tag newest))
  (def on-disk (let [[ok s] (protect (slurp "CHANGELOG.md"))] (if ok (string s) "")))
  (unless (= (released-part on-disk) (released-part text))
    (set failed true)
    (eprint (string "CHANGELOG.md is behind the tags: run "
                    "`janet scripts/gen-changelog.janet` and commit the result")))
  (if failed
    (os/exit 1)
    (printf "CHANGELOG.md matches the history through %s; version %s is not behind it"
            newest core/version)))

(defn main [&opt _ mode]
  (when (= mode "check") (check) (os/exit 0))
  (def {:text text :tags ts :pending pending} (render))
  (spit "CHANGELOG.md" text)
  (printf "CHANGELOG.md written (%d releases%s)"
          (length ts) (if (empty? pending) "" " + unreleased"))
  (unless (empty? skipped)
    (eprintf (string "skipped %s: not in this history (a rewritten commit), "
                     "so neither a boundary nor a section — see `tags`")
             (string/join skipped ", "))))
