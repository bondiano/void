### Generate the docs site — static HTML in site/ — from what the
### repository already says about itself (ROADMAP «Сквозные работы»:
### docs-сайт как генерация из деклараций).
###
### Two kinds of page, one principle:
###
###   * the documents (README, SPEC, ROADMAP, CONTRACTS, DEPLOY, BENCH,
###     CONTRIBUTING, every ADR) are rendered from their Markdown —
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
  "Markdown sources and the pages they become. :here names the nav
  entry the page lights up."
  @[{:src "README.md" :out "index.html" :here "index.html"}
    {:src "docs/SPEC.md" :out "spec.html" :here "spec.html"}
    {:src "docs/ROADMAP.md" :out "roadmap.html" :here "roadmap.html"}
    {:src "docs/CONTRACTS.md" :out "contracts.html" :here "contracts.html"}
    {:src "docs/DEPLOY.md" :out "deploy.html" :here "deploy.html"}
    # the §9 metric, measured on examples/hub rather than asserted
    {:src "docs/IDEA-TO-DEPLOY.md" :out "idea-to-deploy.html" :here "idea-to-deploy.html"}
    {:src "docs/BENCH-v0.1.md" :out "bench.html" :here "bench.html"}
    {:src "CONTRIBUTING.md" :out "contributing.html" :here nil}
    # itself a projection (scripts/gen-changelog.janet) — the site
    # renders it like CONTRACTS: a projection of a projection
    {:src "CHANGELOG.md" :out "changelog.html" :here nil}
    {:src "docs/adr/README.md" :out "adr/index.html" :here "adr/index.html"}])

(each f (sorted (os/dir "docs/adr"))
  (when (and (string/has-suffix? ".md" f) (not= "README.md" f))
    (array/push doc-pages
                {:src (string "docs/adr/" f)
                 :out (string "adr/" (string/slice f 0 -4) ".html")
                 :here "adr/index.html"})))

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

# -- pages ---------------------------------------------------------------

(var- generated-line
  "The footer's provenance line, set by main before any page renders."
  nil)

(defn- write-page! [{:out out :title title :here here :body body}]
  (def path (string out-dir "/" out))
  (def dir (string/join (array/slice (string/split "/" path) 0 -2) "/"))
  (os/mkdir dir)
  (spit path
        (page/render {:title title :here here :depth (depth-of out)
                      :body body :generated generated-line}))
  (print "  " path))

(defn- doc-page! [{:src src :out out :here here}]
  (def source (slurp src))
  (write-page! {:out out :here here
                :title (or (md/title source) src)
                :body (md/parse source {:rewrite-link (rewriter src out)})}))

(defn- config-page! []
  (def body @[[:h1 "Config reference"]
              [:p "Every plugin's slice of the configuration, projected "
               "from the manifests of the in-repo composition — the "
               "schema a value is validated against before the system "
               "starts (ADR-0007), and the defaults the kernel merges "
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
  (write-page! {:out "config.html" :here "config.html"
                :title "Config reference" :body body}))

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
  (write-page! {:out "cli.html" :here "cli.html"
                :title "CLI reference" :body body}))

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
  (os/mkdir (string out-dir "/adr"))
  (set generated-line
       (string "generated from "
               (or (git-sha) "the working tree")
               " on " (os/strftime "%Y-%m-%d" (os/time))))
  (spit (string out-dir "/style.css") page/css)
  (print "site/")
  (each d doc-pages (doc-page! d))
  (config-page!)
  (cli-page!)
  (printf "%d pages, %d plugins, %d CLI commands"
          (+ 2 (length doc-pages))
          (length (keys (boot :manifests)))
          (length (or (get-in boot [:extensions :void.core/cli :resolved]) []))))
