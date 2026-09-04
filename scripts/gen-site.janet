### Generate the docs site — static HTML in site/ — from what the
### repository already says about itself: the docs site is generated
### from the declarations.
###
### Two kinds of page, one principle:
###
###   * the documents (README, CONTRACTS, DEPLOY, BENCH, CONTRIBUTING, ...) are rendered from their Markdown —
###     CONTRACTS.md is itself generated from the declarations and
###     drift-checked in CI, so the site's contract reference is a
###     projection of a projection and cannot disagree with the code;
###   * the reference pages that exist nowhere else — the config
###     reference (every plugin's slice, schema and defaults) and the
###     CLI reference (every `void` command) — are projected here
###     directly from the bootstrapped composition, phases 1-5,
###     nothing started. No page is written by hand, which is the only
###     way a page stays true.
###
### The renderer is void/html's own hiccup — the site is built by the
### framework it documents. Run from the repository root:
###
###     janet scripts/gen-site.janet          # -> site/
###
### CI builds it the same way and publishes site/ to GitHub Pages.

(import ./packages :as packages)

(packages/add-paths (packages/packages))

(import spork/json)

(import ./site/markdown :as md)
(import ./site/page :as page)
(import void/core/plugin :as plugin)

# -- the composition, phases 1-5 -----------------------------------------
#
# The same composition the dry-run gate checks (scripts/dry-run.janet),
# minus the example plugins: the reference should document what the
# framework ships, not what the demo composes on top.

(require "void/http/init")
(require "void/html/init")
(require "void/htmx/init")
(require "void/rest/init")
(require "void/openapi/init")
(require "void/db/init")
(require "void/db-sqlite/init")
(require "void/db-postgres/init")
(require "void/db-mysql/init")
(require "void/db/http")
(require "void/redis/init")
(require "void/redis/http")
(require "void/cache/init")
(require "void/cache/redis")
(require "void/cache/http")
(require "void/jobs/init")
(require "void/jobs/db")
(require "void/jobs/redis")
(require "void/pressure/init")
(require "void/pressure/http")
(require "void/obs/init")
(require "void/obs/http")
(require "void/obs/otlp")
(require "void/crypto/init")
(require "void/auth/init")
(require "void/auth/http")
(require "void/auth/db")
(require "void/auth/oauth")
(require "void/oauth/init")
(require "void/i18n/init")
(require "void/authz/init")
(require "void/authz/http")
(require "void/security/init")
(require "void/mail/init")
(require "void/mail/jobs")
(require "void/mail/auth")
(require "void/bus/init")
(require "void/bus/db")
(require "void/bus/jobs")
(require "void/kafka/init")
(require "void/kafka/bus")
(require "void/ws/init")
(require "void/ws/htmx")
(require "void/proto/init")
(require "void/grpc/init")
(require "void/mcp/init")
(require "void/mcp/http")
(require "void/mcp/obs")
(require "void/admin/init")
(require "void/admin/jobs")
(require "void/admin/mcp")
(require "void/storage/init")
(require "void/storage/http")
(require "void/storage/s3")
(require "void/storage/admin")
(require "void/notify/init")
(require "void/notify/mail")
(require "void/notify/inapp")
(require "void/notify/webhook")
(require "void/notify/jobs")
(require "void/tls/init")
(require "void/datastar/init")
(require "void/dev/init")
(require "void/bench/init")

(def boot
  (plugin/bootstrap
    {:plugins [:void/http :void/html :void/htmx :void/rest :void/openapi
               :void/db :void/db-sqlite :void/db-postgres :void/db-mysql :void/db-http
               :void/redis :void/redis-http
               :void/cache :void/cache-redis :void/cache-http
               :void/jobs :void/jobs-db :void/jobs-redis
               :void/pressure :void/pressure-http
               :void/obs :void/obs-http :void/obs-otlp
               :void/crypto :void/auth :void/auth-http :void/auth-db :void/auth-oauth
               :void/oauth :void/i18n
               :void/authz :void/authz-http :void/security
               :void/mail :void/mail-jobs :void/mail-auth
               :void/bus :void/bus-db :void/bus-jobs
               :void/kafka :void/kafka-bus
               :void/ws :void/ws-htmx
               :void/proto :void/grpc
               :void/mcp :void/mcp-http :void/mcp-obs
               :void/admin :void/admin-jobs :void/admin-mcp
               :void/storage :void/storage-http :void/storage-s3 :void/storage-admin
               :void/notify :void/notify-mail :void/notify-inapp :void/notify-webhook :void/notify-jobs
               :void/tls :void/datastar
               :void/dev :void/bench]
     :profile :dev
     # the ambiguity picks every gate makes: several plugins provide
     # each of these interfaces, and choosing is the application's job
     # — here the generator is the application
     :config {:cli {:bus {:backend :db}
                    :void/db-driver {:impl :db.sqlite/driver}
                    :void/cache-store {:impl :cache/redis}
                    :void/jobs-backend {:impl :jobs/redis}
                    :void/auth-user-store {:impl :auth.db/users}
                    :void/auth-token-store {:impl :auth.db/tokens}
                    :void/auth-challenge-store {:impl :auth.db/challenges}
                    :void/storage-store {:impl :storage/s3}
                    :storage-s3 {:endpoint "http://minio.invalid:9000" :bucket "docs"
                                 :access-key "docs" :secret-key "docs-secret"}}}}))

# -- where each document lives as a page ---------------------------------

(def out-dir "site")

(def doc-pages
  ``Markdown sources and the pages they become. :here names the nav
  entry the page lights up — `index.html` is not among them: the landing
  is the one page built rather than rendered, and the README it draws from
  is a document like any other, at overview.html.``
  @[{:src "README.md" :out "overview.html" :here "overview.html"}
    # the tutorial: install -> running app -> single binary, with the
    # outputs the CLI actually prints — first in the nav, because it is
    # the page a newcomer is looking for
    {:src "docs/GETTING-STARTED.md" :out "getting-started.html" :here "getting-started.html"}
    {:src "docs/COMPARISON.md" :out "comparison.html" :here "comparison.html"}
    {:src "docs/cookbook/README.md" :out "cookbook/index.html" :here "cookbook/index.html"}
    {:src "docs/CONTRACTS.md" :out "contracts.html" :here "contracts.html"}
    {:src "docs/DEPLOY.md" :out "deploy.html" :here "deploy.html"}
    # the idea-to-deploy time, measured on examples/hub rather than asserted
    {:src "docs/IDEA-TO-DEPLOY.md" :out "idea-to-deploy.html" :here "idea-to-deploy.html"}
    {:src "docs/BENCH-v0.1.md" :out "bench.html" :here "bench.html"}
    {:src "CONTRIBUTING.md" :out "contributing.html" :here nil}
    # itself a projection (scripts/gen-changelog.janet) — the site
    # renders it like CONTRACTS: a projection of a projection
    {:src "CHANGELOG.md" :out "changelog.html" :here "changelog.html"}])

# The children a section unfolds in the sidebar: [label href], in the
# order the pages themselves are in. Every one is the document's own first
# heading — a hand-kept list of links is a list that goes stale.

(def cookbook-nav @[])

(each f (sorted (os/dir "docs/cookbook"))
  (when (and (string/has-suffix? ".md" f) (not= "README.md" f))
    (def src (string "docs/cookbook/" f))
    (def out (string "cookbook/" (string/slice f 0 -4) ".html"))
    (array/push cookbook-nav [(or (md/title (slurp src)) f) out])
    (array/push doc-pages {:src src :out out :here "cookbook/index.html"})))

(def module-nav
  "The packages under Modules, by their bundle name."
  (seq [pkg :in (packages/packages)]
    [(string pkg)
     (string "modules/" (get-in packages/graph [pkg :dir]) ".html")]))

(def subnavs
  "Which children each section unfolds."
  {"cookbook/index.html" cookbook-nav
   "modules/index.html" module-nav})

(def page-for
  "repo path of a .md -> site path of its page."
  (tabseq [d :in doc-pages] (d :src) (d :out)))

# -- links between documents ---------------------------------------------

(defn- normalize
  "Collapse ./ and ../ in a repo-relative path."
  [path]
  (def parts @[])
  (each part (string/split "/" path)
    (case part
      "" nil
      "." nil
      ".." (array/pop parts)
      (array/push parts part)))
  (string/join parts "/"))

(defn- depth-of [out] (length (string/find-all "/" out)))

(defn- rewriter
  ``The link rewriter for a page: a relative .md link becomes the
  matching page, kept relative so the site works from any prefix; a
  relative link to anything that is not a page (source files, a
  directory) goes to the repository; absolute URLs and bare #anchors
  pass through.``
  [src out]
  (def src-dir (string/join (array/slice (string/split "/" src) 0 -2) "/"))
  (def up (string/repeat "../" (depth-of out)))
  (fn rewrite [url]
    (cond
      (or (string/has-prefix? "http://" url)
          (string/has-prefix? "https://" url)
          (string/has-prefix? "#" url))
      url

      (let [[path frag] (string/split "#" url)
            repo-path (normalize (if (empty? src-dir) path (string src-dir "/" path)))
            target (get page-for repo-path)]
        (if target
          (string up target (if frag (string "#" frag) ""))
          (string page/github "/blob/main/" repo-path))))))

# -- deterministic rendering of janet values -----------------------------

(defn render-value
  "One-line janet rendering with dictionary keys sorted — the same
  discipline gen-contracts.janet applies, for the same reason: the
  page must not depend on table iteration order."
  [s]
  (cond
    (dictionary? s)
    (string "{" (string/join
                  (seq [k :in (sorted (keys s))]
                    (string (render-value k) " " (render-value (s k))))
                  " ")
            "}")
    (indexed? s)
    (string "[" (string/join (map render-value s) " ") "]")
    (or (function? s) (cfunction? s)) "<fn>"
    (string/format "%q" s)))

(defn- clean-doc
  "A docstring as one line of prose: source indentation and line
  breaks are not content."
  [s]
  (when s
    (string/join
      (filter |(not (empty? $))
              (string/split " " (string/replace-all "\n" " " s)))
      " ")))

# -- table of contents ---------------------------------------------------
#
# Long pages (is 110 KB) get a generated contents sidebar and every h2/h3
# gets a self-link — both projections of the heading ids the markdown
# parser (or a reference page) already minted. The sidebar is CSS-only:
# hidden below the width where it would crowd the column, fixed beside it
# above.

(def- toc-levels {:h2 2 :h3 3})

(def- toc-min
  "How many h2/h3 headings a page needs before a contents sidebar
  earns its place."
  5)

(defn- node-text
  "The visible text of a hiccup node — without decorated links (the
  anchor §, a heading's muted source link): those are chrome, not the
  heading."
  [n]
  (cond
    (not (indexed? n)) (string n)
    (and (= :a (first n)) (dictionary? (get n 1)) (get-in n [1 :class])) ""
    (string/join (map node-text (filter |(not (dictionary? $)) (tuple/slice n 1))) "")))

(defn- heading? [n]
  (and (indexed? n) (toc-levels (first n))
       (dictionary? (get n 1)) (get-in n [1 :id])))

(defn- add-anchors
  "Append a self-link to every h2/h3 that has an id — what makes a
  section shareable by pointing at it."
  [body]
  (map (fn [n]
         (if (heading? n)
           [;n [:a {:class "anchor"
                    :href (string "#" (get-in n [1 :id]))
                    :aria-label "Link to this section"} "§"]]
           n))
       body))

(defn- dedup-ids
  ``GitHub's answer to two headings spelled the same (CHANGELOG's
  repeated `Added`): the second occurrence gets -1, the third -2 — so
  every anchor on the page points at exactly one place.``
  [body]
  (def seen @{})
  (map (fn [n]
         (if (and (indexed? n) (keyword? (first n))
                  (dictionary? (get n 1)) (get-in n [1 :id]))
           (let [id (get-in n [1 :id])
                 k (get seen id 0)]
             (put seen id (inc k))
             (if (zero? k)
               n
               [(first n) (merge (n 1) {:id (string id "-" k)})
                ;(tuple/slice n 2)]))
           n))
       body))

(defn- prepare
  ``Everything a body needs before it becomes a page: heading ids made
  unique, a self-link on every h2/h3, the contents rail when the page has
  enough headings to earn one, and the heading list itself — the rail and
  the search index are two readings of one list.``
  [body]
  (def body (dedup-ids body))
  (def entries
    (seq [n :in body :when (heading? n)]
      {:level (toc-levels (first n))
       :id (get-in n [1 :id])
       :text (string/trim (node-text n))}))
  {:body (add-anchors body)
   :entries entries
   :toc (when (>= (length entries) toc-min)
          [:nav {:class "toc" :aria-label "Contents"}
           [:div {:class "toc-title"} "On this page"]
           [:ol ;(seq [e :in entries]
                   [:li {:class (string "toc-h" (e :level))}
                    [:a {:href (string "#" (e :id))} (e :text)]])]])})

# -- pages ---------------------------------------------------------------

(var- generated-line
  "The footer's provenance line, set by main before any page renders."
  nil)

# -- search index --------------------------------------------------------
#
# The box in the top bar answers from site/search.json — one record per
# page: its title, the section it sits in, its headings with their
# anchors, and the opening prose. Written by write-page! itself, from the
# very nodes that became the page, so the index cannot describe a page the
# site does not have.

(def- search-index @[])

(def- snippet-limit 240)

(defn- clip
  ``A string cut to at most n bytes without splitting a UTF-8
  character — half the corpus is Russian, and half a codepoint is not
  text.``
  [s n]
  (if (<= (length s) n)
    s
    (do
      (var i n)
      (while (and (> i 0) (= 0x80 (band 0xC0 (s i)))) (-- i))
      (string (string/slice s 0 i) "…"))))

(defn- opening-prose
  "The page's first paragraph as plain text, cut to a snippet."
  [body]
  (def para (find |(and (indexed? $) (= :p (first $))) body))
  (when para
    (clip (string/trim (node-text para)) snippet-limit)))

(defn- index-page! [out title here entries body]
  (array/push search-index
              # the landing carries no title of its own
              {"t" (or title "void")
               "n" (page/short-name out title)
               "u" out
               "s" (page/section here)
               "x" (or (opening-prose body) "")
               "h" (seq [e :in entries] {"t" (e :text) "i" (e :id)})}))

(defn- write-page! [{:out out :title title :here here :body body :toc toc
                     :lang lang :subnav subnav :layout layout
                     :entries entries}]
  (def path (string out-dir "/" out))
  (def dir (string/join (array/slice (string/split "/" path) 0 -2) "/"))
  (os/mkdir dir)
  (spit path
        (page/render {:title title :here here :self out :depth (depth-of out)
                      :body body :toc toc :generated generated-line
                      :lang lang :subnav subnav :layout layout}))
  (index-page! out title here (or entries []) body)
  (print "  " path))

(defn- doc-lang
  ``"ru" when the document is mostly Cyrillic prose, "en" otherwise —
  measured, not listed, so a translated document changes its own lang
  attribute.``
  [src]
  (def cyr (count |(or (= $ 0xD0) (= $ 0xD1)) src))
  (if (> (* 10 cyr) (length src)) "ru" "en"))

(defn- assert-no-raw-tables!
  ``Refuse a page with an unparsed table: a paragraph that begins with
  a pipe is a table row the parser did not take — the exact regression
  scripts/site/markdown.janet's separator PEG once shipped.``
  [src node]
  (when (indexed? node)
    (if (= :p (first node))
      (let [head (find string? (array/slice node 1))]
        (when (and head (string/has-prefix? "|" head))
          (errorf "%s: unparsed table row %q — the markdown parser did not take a table"
                  src head)))
      (each child node (assert-no-raw-tables! src child)))))

(defn- doc-page! [{:src src :out out :here here}]
  (def source (slurp src))
  (def body (md/parse source {:rewrite-link (rewriter src out)}))
  (each node body (assert-no-raw-tables! src node))
  (def page-body (prepare body))
  (write-page! {:out out :here here :subnav (get subnavs here)
                :title (or (md/title source) src)
                :lang (doc-lang source)
                :body (page-body :body) :toc (page-body :toc)
                :entries (page-body :entries)}))

(defn- config-page! []
  (def body @[[:h1 "Config reference"]
              [:p "Every plugin's slice of the configuration, projected "
               "from the manifests of the in-repo composition — the "
               "schema a value is validated against before the system "
               "starts, and the defaults the kernel merges "
               "under it. A plugin with no config key is listed for its "
               "components alone."]])
  (each name (sorted (keys (boot :manifests)))
    (def m (get-in boot [:manifests name]))
    (array/push body [:h2 {:id (md/slug (string name))} [:code (string name)]])
    (when-let [doc (clean-doc (m :doc))]
      (array/push body [:p doc]))
    (when-let [key (m :config-key)]
      (array/push body
                  [:p "Config slice: " [:code (string/format "[%q]" key)]])
      (when-let [schema (m :config-schema)]
        (array/push body [:pre [:code (render-value schema) "\n"]]))
      (when-let [defaults (m :config-defaults)]
        (unless (and (dictionary? defaults) (empty? defaults))
          (array/push body
                      [:p {:class "muted"} "Defaults: "
                       [:code (render-value defaults)]]))))
    (def components (or (m :components) []))
    (unless (empty? components)
      (array/push body
                  [:dl {:class "ref"}
                   ;(mapcat
                      (fn [c]
                        [[:dt [:code (string (c :key))]
                          ;(seq [p :in (or (c :provides) [])]
                             [:span {:class "tag"} (string "provides " p)])]
                         [:dd (or (clean-doc (c :doc)) "")]])
                      components)])))
  (def page-body (prepare body))
  (write-page! {:out "config.html" :here "config.html"
                :title "Config reference" :body (page-body :body)
                :toc (page-body :toc) :entries (page-body :entries)}))

(defn- cli-page! []
  (def commands
    (sorted-by
      |($ :spelling)
      (seq [c :in (or (get-in boot [:extensions :void.core/cli :resolved]) [])]
        (merge c {:spelling (string/join (string/split "/" (string (c :name))) " ")}))))
  (def body @[[:h1 "CLI reference"]
              [:p "Every command the " [:code "void"] " binary answers in "
               "this composition — commands are contributions to "
               [:code ":void.core/cli"] ", so a plugin brings its own and "
               "an application adds more the same way. A command's "
               [:code ":needs"] " is the subset of the system it boots "
               "(nothing else starts)."]
              [:dl {:class "ref"}
               ;(mapcat
                  (fn [c]
                    [[:dt [:code (string "void " (c :spelling))]
                      (when (c :read-only?)
                        [:span {:class "tag ro"} "read-only"])]
                     [:dd (or (clean-doc (c :doc)) "")
                      (let [needs (or (c :needs) [])]
                        (unless (empty? needs)
                          [:span {:class "muted"}
                           (string " — boots " (string/join (map string needs) ", "))]))]])
                  commands)]])
  (def page-body (prepare body))
  (write-page! {:out "cli.html" :here "cli.html"
                :title "CLI reference" :body (page-body :body)
                :toc (page-body :toc) :entries (page-body :entries)}))

# -- module reference ----------------------------------------------------
#
# One page per package of the bundle, projected from what the package
# already says about itself: the :description of its project.janet,
# the manifests of its plugins (doc, config slice, components,
# extension points, contributions), the CLI commands those plugins
# contribute, and — the part no other page has — every documented
# public binding of every module in its tree, read by importing the
# module into this generator's composition and walking the module
# environment. Docstrings are the source of every word; nothing on
# these pages is written here.

(defn- repo-rel
  "A path under the repository root, made repo-relative."
  [path]
  (def prefix (string packages/root "/"))
  (if (string/has-prefix? prefix path)
    (string/slice path (length prefix))
    path))

(defn- package-description
  "The :description string of a package's project.janet."
  [dir]
  (def path (string packages/root "/" dir "/project.janet"))
  (when (= :file (os/stat path :mode))
    (def p (parser/new))
    (parser/consume p (slurp path))
    (parser/eof p)
    (var found nil)
    (while (parser/has-more p)
      (def form (parser/produce p))
      (when (and (indexed? form) (= 'declare-project (first form)))
        (def kvs (drop 1 form))
        (loop [i :range [0 (length kvs)]
               :when (= :description (get kvs i))]
          (set found (get kvs (inc i))))))
    (when (string? found) found)))

(defn- module-files
  "Every .janet file of a package's void/ tree, sorted."
  [dir]
  (def out @[])
  (defn walk [p]
    (each f (sorted (os/dir p))
      (def full (string p "/" f))
      (case (os/stat full :mode)
        :directory (walk full)
        :file (when (string/has-suffix? ".janet" f)
                (array/push out full)))))
  (def base (string packages/root "/" dir "/void"))
  (when (= :directory (os/stat base :mode)) (walk base))
  out)

(defn- module-of
  "The import name of a module file: <dir>/void/http/router.janet ->
  void/http/router, with a trailing /init folded away."
  [dir file]
  (def base (string packages/root "/" dir "/void/"))
  (def rel (string/slice file (length base) -7))
  (def name (string "void/" rel))
  (if (string/has-suffix? "/init" name)
    (string/slice name 0 -6)
    name))

(defn- module-bindings
  "The documented public bindings of a module, in source order:
  {:sym :doc :kind :line :file}. Nil when the module does not load in
  this composition (nothing in the bundle currently refuses)."
  [name]
  (def [ok env] (protect (require name)))
  (when ok
    (sorted-by
      |($ :line)
      (seq [[sym meta] :pairs env
            :when (and (symbol? sym) (table? meta)
                       (string? (meta :doc)) (not (meta :private)))]
        (def v (if (nil? (get meta :value)) (get-in meta [:ref 0]) (meta :value)))
        (def sm (meta :source-map))
        {:sym sym
         :doc (meta :doc)
         :kind (cond (meta :macro) "macro"
                     (or (function? v) (cfunction? v)) "fn"
                     "value")
         :line (get sm 1 0)
         :file (get sm 0)}))))

(defn- dedent-doc
  "A docstring's lines with the source indentation of the continuation
  lines removed — the first line never carries any."
  [doc]
  (def lines (string/split "\n" doc))
  (def rest-lines (drop 1 lines))
  (def indents
    (seq [l :in rest-lines :when (not (empty? (string/trim l)))]
      (- (length l) (length (string/triml l)))))
  (def cut (if (empty? indents) 0 (min ;indents)))
  [(first lines)
   ;(map |(if (<= (length $) cut) "" (string/slice $ cut)) rest-lines)])

(defn- doc-hiccup
  "A docstring as hiccup blocks: blank-line paragraphs, and a block
  whose every line is indented four spaces is a usage example — the
  convention the corpus's docstrings already follow."
  [doc]
  (def blocks @[])
  (def cur @[])
  (defn flush! []
    (unless (empty? cur)
      (array/push blocks (tuple ;cur))
      (array/clear cur)))
  (each line (dedent-doc doc)
    (if (empty? (string/trim line)) (flush!) (array/push cur line)))
  (flush!)
  (seq [b :in blocks]
    (if (all |(string/has-prefix? "    " $) b)
      [:pre [:code (string (string/join (map |(string/slice $ 4) b) "\n") "\n")]]
      [:p ;(md/inline-markup (string/join (map string/trim b) " "))])))

(defn- contribution-entry
  "One contributed value as [dt-content dd-content]: named
  contributions show their name and doc, anonymous ones their value."
  [c]
  (def v (c :value))
  (def label (when (dictionary? v) (or (v :name) (v :key))))
  (if label
    [[:code (string label)]
     (or (clean-doc (v :doc)) "")]
    [[:code (let [r (render-value v)]
              (if (> (length r) 100) (string (string/slice r 0 100) "…") r))]
     ""]))

(defn- plugin-section!
  "The manifest of one plugin as page blocks, pushed onto body."
  [body m cli-contribs]
  (def name (m :name))
  (array/push body [:h2 {:id (md/slug (string name))} [:code (string name)]])
  (when-let [doc (clean-doc (m :doc))]
    (array/push body [:p doc]))
  (def requires (m :requires))
  (unless (or (nil? requires) (empty? requires))
    (array/push body
                [:p {:class "muted"} "Requires: "
                 ;(mapcat |[[:code (string $)] " "] (sorted (keys requires)))]))
  (when-let [key (m :config-key)]
    (array/push body
                [:p "Config slice: " [:code (string/format "[%q]" key)]
                 " — see the " [:a {:href "../config.html"} "config reference"]
                 " for the schema and defaults."])
    (when-let [defaults (m :config-defaults)]
      (unless (and (dictionary? defaults) (empty? defaults))
        (array/push body
                    [:p {:class "muted"} "Defaults: "
                     [:code (render-value defaults)]]))))
  (def components (or (m :components) []))
  (unless (empty? components)
    (array/push body [:p [:strong "Components"]])
    (array/push body
                [:dl {:class "ref"}
                 ;(mapcat
                    (fn [c]
                      [[:dt [:code (string (c :key))]
                        ;(seq [p :in (or (c :provides) [])]
                           [:span {:class "tag"} (string "provides " p)])]
                       [:dd (or (clean-doc (c :doc)) "")]])
                    components)]))
  (def points (or (m :extension-points) {}))
  (unless (empty? points)
    (array/push body [:p [:strong "Extension points"]])
    (array/push body
                [:dl {:class "ref"}
                 ;(mapcat
                    (fn [pname]
                      (def point (points pname))
                      [[:dt [:code (string pname)]
                        [:span {:class "tag"}
                         (string (get point :cardinality :many))]]
                       [:dd (or (clean-doc (point :doc)) "")]])
                    (sorted (keys points)))]))
  (def contributes (or (m :contributes) {}))
  (unless (empty? contributes)
    (array/push body [:p [:strong "Contributes"]])
    (each pname (sorted (keys contributes))
      (array/push body
                  [:p {:class "muted"} "to " [:code (string pname)] ":"])
      (array/push body
                  [:dl {:class "ref"}
                   ;(mapcat
                      (fn [v]
                        (def [dt dd] (contribution-entry {:value v}))
                        [[:dt dt] [:dd dd]])
                      (contributes pname))])))
  (unless (empty? cli-contribs)
    (array/push body [:p [:strong "CLI commands"]])
    (array/push body
                [:dl {:class "ref"}
                 ;(mapcat
                    (fn [c]
                      (def spelling
                        (string/join (string/split "/" (string (c :name))) " "))
                      [[:dt [:code (string "void " spelling)]
                        (when (c :read-only?)
                          [:span {:class "tag ro"} "read-only"])]
                       [:dd (or (clean-doc (c :doc)) "")]])
                    cli-contribs)])))

(defn- package-page!
  "One package's reference page: site/modules/<dir>.html."
  [pkg]
  (def dir (get-in packages/graph [pkg :dir]))
  (def marker (string "/" dir "/void/"))
  (def plugin-names
    (sorted (seq [name :in (keys (boot :manifests))
                  :let [m (get-in boot [:manifests name])]
                  :when (and (m :source) (string/find marker (m :source)))]
              name)))
  (def plugin-set (tabseq [n :in plugin-names] n true))
  (def cli-by-plugin @{})
  (each c (or (get-in boot [:extensions :void.core/cli :contributions]) [])
    (when (plugin-set (c :plugin))
      (def arr (or (cli-by-plugin (c :plugin))
                   (let [a @[]] (put cli-by-plugin (c :plugin) a) a)))
      (array/push arr (c :value))))
  (def body @[[:h1 [:code (string pkg)]]])
  (when-let [desc (package-description dir)]
    (array/push body [:p desc]))
  (array/push body
              [:p {:class "muted"}
               "Source: "
               [:a {:href (string page/github "/tree/main/" dir)}
                [:code (string dir "/")]]
               " · every entry below is projected from the package's "
               "declarations and docstrings."])
  (each name plugin-names
    (plugin-section! body (get-in boot [:manifests name])
                     (sorted-by |(string ($ :name))
                                (get cli-by-plugin name []))))
  (def files (module-files dir))
  (unless (empty? files)
    (array/push body [:h2 {:id "api"} "API"])
    (array/push body
                [:p "The documented public bindings of every module in "
                 "the package, read from the modules themselves — name, "
                 "kind, docstring, and where the definition lives."]))
  (each file files
    (def mod (module-of dir file))
    (def bindings (module-bindings mod))
    (def gh-file (string page/github "/blob/main/" (repo-rel file)))
    (array/push body
                [:h3 {:id (string "api-" (md/slug mod))}
                 [:code mod]
                 " " [:a {:class "muted" :href gh-file} "source"]])
    (cond
      (nil? bindings)
      (array/push body
                  [:p {:class "muted"}
                   "Not loadable in the reference composition — see the source."])

      (empty? bindings)
      (array/push body
                  [:p {:class "muted"} "No documented public bindings."])

      (array/push body
                  [:dl {:class "ref"}
                   ;(mapcat
                      (fn [b]
                        [[:dt [:a {:href (string gh-file "#L" (b :line))}
                               [:code (string (b :sym))]]
                          [:span {:class "tag"} (b :kind)]]
                         [:dd ;(doc-hiccup (b :doc))]])
                      bindings)])))
  (def page-body (prepare body))
  (write-page! {:out (string "modules/" dir ".html")
                :here "modules/index.html" :subnav module-nav
                :title (string pkg)
                :body (page-body :body) :toc (page-body :toc)
                :entries (page-body :entries)}))

(defn- modules-pages!
  "The per-package pages plus their index. Returns how many pages."
  []
  (def pkgs (packages/packages))
  (def body
    @[[:h1 "Modules"]
      [:p "One page per package of the bundle — its plugins with their "
       "config slices, components, extension points and contributions, "
       "the CLI commands they bring, and the documented public bindings "
       "of every module, projected from the code the way the "
       [:a {:href "../config.html"} "config"] " and "
       [:a {:href "../cli.html"} "CLI"] " references are. "
       "No page here is written by hand."]
      [:div {:class "table-wrap"}
       [:table
        [:thead [:tr [:th "Package"] [:th "Description"]]]
        [:tbody
         ;(seq [pkg :in pkgs]
            (def dir (get-in packages/graph [pkg :dir]))
            [:tr
             [:td [:a {:href (string dir ".html")} [:code (string pkg)]]]
             [:td (or (package-description dir) "")]])]]]])
  (write-page! {:out "modules/index.html" :here "modules/index.html"
                :subnav module-nav :title "Modules" :body body})
  (each pkg pkgs (package-page! pkg))
  (inc (length pkgs)))

# -- the landing ---------------------------------------------------------
#
# The one page that is not a rendered document — and still not written
# here. Its words are the README's own (the opening claim, the quick
# start, «Where void fits»), its numbers are counted off the bootstrapped
# composition, and each card describes where it leads with that document's
# first sentence. What this file contributes is the arrangement.

(def- heading-level {:h1 1 :h2 2 :h3 3 :h4 4})

(defn- first-of
  "The first block of a kind, or nil."
  [blocks tag]
  (find |(and (indexed? $) (= tag (first $))) blocks))

(defn- section-blocks
  ``The blocks under the heading with this id, up to the next heading
  of the same or a higher level — how the landing quotes a section of the
  README without repeating a word of it.``
  [blocks id]
  (var level nil)
  (def out @[])
  (each n blocks
    (def lvl (and (indexed? n) (heading-level (first n))))
    (cond
      (and (nil? level) lvl (= id (get-in n [1 :id])))
      (set level lvl)

      (nil? level) nil

      (and lvl (<= lvl level)) (break)

      (array/push out n)))
  out)

(defn- first-sentence
  "A document's opening sentence, for the card that leads to it."
  [src]
  (def para (first-of (md/parse (slurp src)) :p))
  (when para
    (def text (string/trim (node-text para)))
    (def stop (string/find ". " text))
    (clip (if stop (string/slice text 0 (inc stop)) text) 190)))

(def- landing-cards
  ``Where the landing sends a reader, in reading order. A card with a
  :src takes its blurb from that document; the three generated references
  have no document to quote, so their one line lives here — the same
  sentence their own page opens with.``
  [{:label "Getting started" :href "getting-started.html"
    :src "docs/GETTING-STARTED.md"}
   {:label "Cookbook" :href "cookbook/index.html"
    :src "docs/cookbook/README.md"}
   {:label "Modules" :href "modules/index.html"
    :blurb "One page per package: its plugins with their config slices, components and extension points, and every documented binding of every module."}
   {:label "Config reference" :href "config.html"
    :blurb "Every plugin's slice of the configuration — the schema a value is validated against before the system starts, and the defaults the kernel merges under it."}
   {:label "CLI reference" :href "cli.html"
    :blurb "Every command the void binary answers, and the subset of the system each one boots."}
   {:label "Contracts" :href "contracts.html" :src "docs/CONTRACTS.md"}
   {:label "Idea → deploy" :href "idea-to-deploy.html"
    :src "docs/IDEA-TO-DEPLOY.md"}
   {:label "Deploy" :href "deploy.html" :src "docs/DEPLOY.md"}
   {:label "Compared" :href "comparison.html" :src "docs/COMPARISON.md"}
   {:label "Benchmarks" :href "bench.html" :src "docs/BENCH-v0.1.md"}])

(defn- landing! []
  (def readme (md/parse (slurp "README.md")
                        {:rewrite-link (rewriter "README.md" "index.html")}))
  (def lede (first-of readme :p))
  (def quick (first-of (section-blocks readme (md/slug "Quick start")) :pre))
  (def fits (take 2 (filter |(and (indexed? $) (= :p (first $)))
                            (section-blocks readme (md/slug "Where void fits")))))
  (def stats
    [[(length (packages/packages)) "packages"]
     [(length (keys (boot :manifests))) "plugins"]
     [(length (keys (boot :extensions))) "extension points"]
     [(length (or (get-in boot [:extensions :void.core/cli :resolved]) []))
      "CLI commands"]])
  (write-page!
    {:out "index.html" :here nil :title nil :layout :landing
     :body
     @[[:section {:class "hero"}
        [:h1 "void"]
        (when lede [:p {:class "lede"} ;(tuple/slice lede 1)])
        [:div {:class "cta"}
         [:a {:class "primary" :href "getting-started.html"} "Getting started"]
         [:a {:class "ghost" :href "overview.html"} "Overview"]
         [:a {:class "ghost" :href page/github} "Source"]]]
       [:div {:class "strip"}
        ;(seq [[n label] :in stats]
           [:div [:div {:class "n"} (string n)] [:div {:class "k"} label]])]
       [:h2 "Quick start"]
       (or quick "")
       [:h2 "Where void fits"]
       [:div {:class "prose"} ;fits]
       [:h2 "Read"]
       [:div {:class "cards"}
        ;(seq [c :in landing-cards]
           [:a {:class "card" :href (c :href)}
            [:div {:class "t"} (c :label)]
            [:div {:class "d"}
             (or (c :blurb) (when (c :src) (first-sentence (c :src))) "")]])]]}))

# -- main ----------------------------------------------------------------

(defn- git-sha []
  (def [ok sha]
    (protect
      (with [p (os/spawn ["git" "rev-parse" "--short" "HEAD"] :px {:out :pipe})]
        (def out (string/trim (string (ev/read (p :out) 64))))
        (os/proc-wait p)
        out)))
  (when (and ok (not (empty? sha))) sha))

(defn main [&]
  (os/mkdir out-dir)
  (set generated-line
       (string "generated from "
               (or (git-sha) "the working tree")
               " on " (os/strftime "%Y-%m-%d" (os/time))))
  (spit (string out-dir "/style.css") page/css)
  (spit (string out-dir "/site.js") (slurp "scripts/site/site.js"))
  (print "site/")
  (landing!)
  (each d doc-pages (doc-page! d))
  (config-page!)
  (cli-page!)
  (def module-pages (modules-pages!))
  (spit (string out-dir "/search.json") (json/encode search-index))
  (printf "%d pages, %d plugins, %d CLI commands, %d module pages, search index %d KB"
          (length search-index)
          (length (keys (boot :manifests)))
          (length (or (get-in boot [:extensions :void.core/cli :resolved]) []))
          (dec module-pages)
          (div (length (json/encode search-index)) 1024)))
