### Generate CHANGELOG.md from the git history — a projection, not
### prose (ROADMAP, волна 7).
###
### The history is already the changelog: every commit here is written
### as `type: subject (wave, ADR-nnnn)`, one commit per landed piece,
### and the tags v0.1..v0.4 mark the wave boundaries. So the changelog
### is not a second document somebody keeps in sync — it is this
### script's output, grouped by release and by type, with every
### ADR-nnnn mention turned into a link to the decision it names. The
### same reasoning as CONTRACTS.md and the docs site: no page written
### by hand stays true.
###
### Run from the repository root:
###
###     janet scripts/gen-changelog.janet     # -> CHANGELOG.md
###
### Commits after the newest tag land in an «Unreleased» section, so
### the file is regenerated at release time (tag first, generate
### second) and may be regenerated any day in between to preview.

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
      {:hash hash :subject subject})))

(def- adr-files
  "ADR number -> filename, scanned once from docs/adr."
  (do
    (def m @{})
    (each f (os/dir "docs/adr")
      (when-let [num (first (peg/match ~(* '(repeat 4 :d) "-") f))]
        (put m num f)))
    m))

(defn- link-adrs
  "Every ADR-nnnn mention becomes a link to the decision it names —
  when the file exists; a dangling number stays plain text rather
  than a broken link."
  [subject]
  (def out @"")
  (var pos 0)
  (def matches (peg/match ~(any (+ (* ($) "ADR-" '(repeat 4 :d)) 1)) subject))
  (each [at num] (partition 2 (or matches []))
    (buffer/push out (string/slice subject pos at))
    (if-let [f (get adr-files num)]
      (buffer/push out (string "[ADR-" num "](docs/adr/" f ")"))
      (buffer/push out (string "ADR-" num)))
    (set pos (+ at 4 4)))
  (buffer/push out (string/slice subject pos))
  (string out))

# -- rendering -----------------------------------------------------------

(def- sections
  "Commit type -> changelog section, in print order."
  [["feat" "Добавлено"]
   ["fix" "Исправлено"]
   ["perf" "Производительность"]
   ["docs" "Документация"]
   [nil "Прочее"]])   # chore/refactor/test/style/revert and anything else

(def- known-types (map first (filter first sections)))

(defn- split-subject
  "\"feat: void/tls — ...\" -> [\"feat\" \"void/tls — ...\"]; a subject
  without a known prefix goes to «Прочее» whole."
  [subject]
  (if-let [colon (string/find ": " subject)]
    (let [t (string/slice subject 0 colon)]
      (if (index-of t known-types)
        [t (string/slice subject (+ colon 2))]
        [nil subject]))
    [nil subject]))

(def- release-themes
  ``One line per checkpoint — mirrors «Контрольные точки релизов» in
  docs/ROADMAP.md, which remains the source; a drift here is a wrong
  label, not a wrong history.``
  {"v0.1" "конец волны 1 — «можно строить HTMX-приложения, есть что показать»; контракты Plugin API и Route Metadata заморожены"
   "v0.2" "конец волны 2 — продуктовый минимум, Laravel-паритет по ядру"
   "v0.3" "конец волны 3 — enterprise-вертикаль: obs/auth/authz/bus"
   "v0.4" "конец волны 4 — killer-фичи: admin + MCP; кандидат в публичный анонс"
   "v0.5" "конец волны 6 — паритет и первое приложение: хранилище, auth-скаффолд, jobs-дашборд, нотификации, tailwind без node, htmx 4 — и examples/hub, задеплоенный"})

(defn- render-release [buf title date theme cs]
  (buffer/push buf "## " title)
  (when date (buffer/push buf " — " date))
  (buffer/push buf "\n\n")
  (when theme (buffer/push buf theme "\n\n"))
  (if (empty? cs)
    (buffer/push buf "*(нет коммитов)*\n\n")
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
            (buffer/push buf "- " (link-adrs (item :text))
                         " (`" (item :hash) "`)\n"))
          (buffer/push buf "\n"))))))

(defn main [& _]
  (def ts (tags))
  (when (empty? ts)
    (error "no release tags — nothing to project"))
  (def buf @"")
  (buffer/push buf
    "# Changelog\n\n"
    "> Проекция git-истории (`scripts/gen-changelog.janet`), не рукопись: "
    "каждый коммит репозитория уже назван по форме `type: что (волна, ADR)`, "
    "теги отмечают границы релизов, ADR-ссылки ведут к решениям. "
    "Файл регенерируется на релизе; правки руками сюда не вносятся — "
    "они вносятся туда, откуда он собран.\n\n")
  # the same sentence the script prints to stderr, put where a reader
  # of the file is: a heading that is missing needs to say so, or the
  # next person goes looking for a bug in the projection
  (unless (empty? skipped)
    (buffer/push buf
      "> " (string/join skipped " и ") " здесь нет: репозиторий однажды "
      "пересобрал историю, и эти теги остались указывать на коммиты, "
      "которых в ней больше нет. Тег, которого история не содержит, не "
      "может быть границей — поэтому релиз ниже охватывает всё, что "
      "накопилось с предыдущего *живого* тега, а границы волн живут в "
      "[ROADMAP](docs/ROADMAP.md).\n\n"))
  # unreleased first, newest release next
  (def newest (last ts))
  (def pending (commits (string newest "..HEAD")))
  (unless (empty? pending)
    (render-release buf "Unreleased" nil
                    (string "после " newest " (ROADMAP)")
                    pending))
  (loop [i :down-to [(dec (length ts)) 0]]
    (def tag (in ts i))
    (def range (if (zero? i) tag (string (in ts (dec i)) ".." tag)))
    (render-release buf tag (tag-date tag) (get release-themes tag)
                    (commits range)))
  (spit "CHANGELOG.md" (string (string/trimr buf "\n") "\n"))
  (printf "CHANGELOG.md written (%d releases%s)"
          (length ts) (if (empty? pending) "" " + unreleased"))
  (unless (empty? skipped)
    (eprintf (string "skipped %s: not in this history (a rewritten commit), "
                     "so neither a boundary nor a section — see `tags`")
             (string/join skipped ", "))))
