### Generate docs/CONTRACTS.md — the frozen v1 contract registry —
### from the declarations themselves (SPEC part II, готовность п. 4:
### «вся документация metadata генерируется из деклараций»). The
### in-repo composition is bootstrapped (phases 1-5, nothing starts)
### and every extension point and every declared route-metadata key is
### rendered from its live declaration; the reserved-for-later tables
### are the hand-maintained data at the bottom of this script. CI
### regenerates the file and fails on drift:
###
###     janet scripts/gen-contracts.janet && git diff --exit-code docs/CONTRACTS.md

(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (os/cwd))
(add-tree (string (os/cwd) "/core"))
(add-tree (string (os/cwd) "/dev"))
(add-tree (string (os/cwd) "/http"))
(add-tree (string (os/cwd) "/html"))
(add-tree (string (os/cwd) "/htmx"))
(add-tree (string (os/cwd) "/rest"))
(add-tree (string (os/cwd) "/openapi"))
(add-tree (string (os/cwd) "/db"))
(add-tree (string (os/cwd) "/db-sqlite"))
(add-tree (string (os/cwd) "/db-postgres"))
(add-tree (string (os/cwd) "/fdwait"))
# void/db-postgres reaches libpq through void/fdwait, the monorepo's one
# native module: build it first (cd fdwait && jpm build).
(array/insert module/paths 0
              [(string (os/cwd) "/fdwait/build/:all:.so") :native])
(add-tree (string (os/cwd) "/redis"))
(add-tree (string (os/cwd) "/cache"))
(add-tree (string (os/cwd) "/jobs"))
(add-tree (string (os/cwd) "/pressure"))
(add-tree (string (os/cwd) "/obs"))
(add-tree (string (os/cwd) "/crypto"))
(add-tree (string (os/cwd) "/auth"))
(add-tree (string (os/cwd) "/authz"))
(add-tree (string (os/cwd) "/security"))
(add-tree (string (os/cwd) "/bench"))

(import void/core/plugin :as plugin)
(import void/http/middleware :as mw)
(require "void/http/init")
(require "void/html/init")
(require "void/htmx/init")
(require "void/rest/init")
(require "void/openapi/init")
(require "void/db/init")
(require "void/db-sqlite/init")
(require "void/db-postgres/init")
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
(require "void/crypto/init")
(require "void/auth/init")
(require "void/auth/http")
(require "void/auth/db")
(require "void/authz/init")
(require "void/authz/http")
(require "void/security/init")
(require "void/dev/init")
(require "void/bench/init")

(def boot
  (plugin/bootstrap
    {:plugins [:void/http :void/html :void/htmx :void/rest :void/openapi
               :void/db :void/db-sqlite :void/db-postgres :void/db-http
               :void/redis :void/redis-http
               :void/cache :void/cache-redis :void/cache-http
               :void/jobs :void/jobs-db :void/jobs-redis
               :void/pressure :void/pressure-http
               :void/obs :void/obs-http
               :void/crypto :void/auth :void/auth-http :void/auth-db
               :void/authz :void/authz-http :void/security
               :void/dev :void/bench]
     :profile :dev
     # two drivers now provide :void/db-driver, two stores provide
     # :void/cache-store, and three backends provide :void/jobs-backend —
     # exactly the ambiguity the kernel refuses to resolve on its own. The
     # gate says which, the way an application's config would (see
     # void/db-postgres, void/cache-redis, void/jobs-redis)
     :config {:cli {:void/db-driver {:impl :db.sqlite/driver}
                    :void/cache-store {:impl :cache/redis}
                    :void/jobs-backend {:impl :jobs/redis}
                    :void/auth-user-store {:impl :auth.db/users}
                    :void/auth-token-store {:impl :auth.db/tokens}
                    :void/auth-challenge-store {:impl :auth.db/challenges}}}}))

# -- deterministic rendering of schema shorthand -------------------------

(defn render-schema
  "One-line janet rendering of a schema shorthand with dictionary keys
  sorted, so regeneration is stable."
  [s]
  (cond
    (dictionary? s)
    (string "{" (string/join
                  (seq [k :in (sorted (keys s))]
                    (string (render-schema k) " " (render-schema (s k))))
                  " ")
            "}")
    (indexed? s)
    (string "[" (string/join (map render-schema s) " ") "]")
    (or (function? s) (cfunction? s)) "<fn>"
    (string/format "%q" s)))

# -- reserved-for-later data (hand-maintained) ---------------------------

(def reserved-keys
  ``Metadata keys reserved by SPEC part II §2.5 whose owner plugins
  land in waves 2+. The names and merge strategies are frozen with v1;
  each plugin declares its keys through :void.http/route-meta-key when
  it ships (an undeclared key stays a boot error until then).``
  [# Wave 3 emptied this table of everything but the bus and admin
   # points below: :void.auth/access, :void.authz/policy,
   # :void.security/csrf and :void.security/rate are all declared by
   # the plugins that own them now, so they are generated from the
   # declarations above — the same thing that happened to
   # :void.obs/name in wave 3.1.
   # (:void.obs/name and :void.obs/sample-rate left it in 3.1 for the
   # same reason.)
   ])

(def reserved-points
  "Extension points reserved by SPEC part I §1.4/ADRs whose owner
  plugins land in waves 2+. Names are frozen with v1."
  # :void.obs/instrument and :void.obs/exporter left this table in wave
  # 3: void/obs owns them, so they are generated above.
  [["`:void.bus/backend`" "void/bus" "message-bus backends (wave 3, ADR-0012)"]
   ["`:void.bus/codec`" "void/bus" "message codecs (wave 3)"]
   ["`:void.admin/widget` `/page` `/dashboard-widget` `/menu`" "void/admin" "admin surfaces (wave 4)"]])

# -- assemble ------------------------------------------------------------

(def out @"")
(defn p [fmt & args] (buffer/push out (string/format fmt ;args) "\n"))

(p "# void contracts — v1 (frozen)")
(p "")
(p "> **AUTOGENERATED** by `janet scripts/gen-contracts.janet` from the")
(p "> declarations in the in-repo composition")
# the composition itself, wrapped — hand-listing it is how the header
# and the gate drift apart the first time a plugin joins
(let [names (map string (boot :plugins))]
  (var line (buffer "> ("))
  (each name names
    (when (> (+ (length line) (length name)) 68)
      (p (string/trimr (string line)))
      (set line (buffer "> ")))
    (buffer/push-string line name " "))
  (p (string (string/trimr (string line)) ")")))
(p "> Do not edit the generated tables by hand — change the declaration")
(p "> and regenerate; CI fails on drift. The reserved-for-later tables")
(p "> are maintained in the generator script.")
(p "")
(p "This is the normative registry of the two contracts frozen at v0.1")
(p "(SPEC part II): the **extension points** with their contribution")
(p "schemas, and the **route metadata keys**. From this tag on, every")
(p "change follows the deprecation procedure in")
(p "[CONTRIBUTING.md](../CONTRIBUTING.md#deprecation): schemas may only")
(p "gain `:optional` fields; a rename or tightening is a **new** point or")
(p "key plus a deprecation alias for the old name, never a mutation.")
(p "")

(p "## Extension points")
(p "")
(each name (sorted (keys (boot :extensions)))
  (def e (get-in boot [:extensions name]))
  (def pt (e :point))
  (p "### `%q`" name)
  (p "")
  (p "- **owner:** `%q` · **cardinality:** `%q`%s"
     (e :owner) (pt :cardinality)
     (let [as (get pt :aliases [])]
       (if (empty? as)
         ""
         (string " · **deprecated aliases:** "
                 (string/join (map |(string/format "`%q`" $) as) ", ")))))
  (when-let [d (pt :doc)]
    (p "- %s" d))
  (if-let [s (pt :schema-source)]
    (do (p "- **contribution schema:**")
        (p "")
        (p "  ```janet")
        (p "  %s" (render-schema s))
        (p "  ```"))
    (p "- **contribution schema:** none (any value)"))
  (p ""))

(p "### Reserved point names (owners land in waves 2+)")
(p "")
(p "| Point | Owner-to-be | What it will register |")
(p "|---|---|---|")
(each [n o d] reserved-points
  (p "| %s | `%s` | %s |" n o d))
(p "")

(p "## Request-lifecycle stages (ADR-0016)")
(p "")
(p "Frozen with v1: stage names and their phase slots. In-chain stages")
(p "compile into the route chain as thin wrappers (an empty stage costs")
(p "nothing); request-side hooks are `(fn [request])` — a response table")
(p "short-circuits — response-side are `(fn [request response]) ->")
(p "response`. Out-of-chain stages are called by the transport (socket")
(p "and inject paths alike): `:on-response` after the bytes are written,")
(p "`:on-error` before the error renderers, `:on-timeout` on a")
(p "`:void.http/timeout` cancellation. Register globally through")
(p "`:void.http/hook`, per-route through the `:void.http/hooks` metadata")
(p "key.")
(p "")
(p "| Stage | Phase slot | Side |")
(p "|---|---|---|")
(each s (sorted-by |(get mw/stage-slots $ 99999) (keys mw/stages))
  (p "| `%q` | %s | %s |"
     s
     (if-let [slot (get mw/stage-slots s)] (string slot) "— (out of chain)")
     (cond
       (get mw/request-stages s) "request"
       (get mw/stage-slots s) "response"
       "transport")))
(p "")

(p "## Route metadata keys")
(p "")
(p "`:name` is the one bare key (required, globally unique). Every")
(p "other key is namespaced and must be declared through")
(p "`:void.http/route-meta-key` — an undeclared key is a boot error")
(p "with did-you-mean. Merge strategies (route ← group ← global):")
(p "`:replace` (specific layer wins), `:concat`, `:deep-merge`,")
(p "`:restrict` (a specific layer may only tighten; violation is a boot")
(p "error). `(http/explain-route path)` prints every value's origin by")
(p "layer.")
(p "")
(p "### Declared in v0.1")
(p "")
(p "| Key | Declared by | Merge | Schema | Doc |")
(p "|---|---|---|---|---|")
(def meta-contribs
  (sorted-by |(get-in $ [:value :key])
             (get-in boot [:extensions :void.http/route-meta-key :contributions] [])))
(each c meta-contribs
  (def v (c :value))
  (p "| `%q` | `%q` | `%q`%s | `%s` | %s |"
     (v :key) (c :plugin)
     (get v :merge :replace)
     (if (v :allow?) " + `:allow?`" "")
     (render-schema (v :schema))
     (get v :doc "")))
(p "")

(p "### Reserved key names (owners land in waves 2+)")
(p "")
(p "| Key | Type | Merge | Owner-to-be |")
(p "|---|---|---|---|")
(if (empty? reserved-keys)
  (p "| — | — | — | *(none: every key SPEC part II §2.5 reserved is now declared by its owner)* |")
  (each [n t m o] reserved-keys
    (p "| %s | %s | %s | %s |" n t m o)))
(p "")
(p "`:void.openapi/*` note: v0.1 declares `tags`, `summary`,")
(p "`description`, `id`, `hidden`; further `:void.openapi/...` names")
(p "stay reserved for void/openapi.")

(spit "docs/CONTRACTS.md" (string out))
(printf "docs/CONTRACTS.md written (%d extension points, %d metadata keys)"
        (length (keys (boot :extensions))) (length meta-contribs))
