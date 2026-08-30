### The shop as an MCP server (ADR-0031): the same thirty-plugin
### composition, read through the projection an agent connects to.
###
### Nothing is started here. `plugin/bootstrap` plus the two hooks is
### exactly the state `void mcp serve` begins in — the graph exists,
### no component is running, and a tool brings its `:needs` with it —
### so this suite asserts on the *exposure*, which is what the
### application decided, rather than on a database it would have to
### migrate first.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/hooks :as hooks)
(import void/core/log :as log)
(import void/mcp :as mcp)
(import ../main)

(log/set-level! "void" :error)

(def boot
  (plugin/bootstrap {:plugins (main/plugins :sqlite)
                     :profile :test
                     :config {:env @{}
                              :cli {:log {:level :error}
                                    :db {:migrations {:dir "db/migrations"}}}}}
                    true))
(hooks/run! (boot :hooks) :config-loaded boot)
(hooks/run! (boot :hooks) :before-start boot)

(def exposed (mcp/exposed))
(def tools (exposed :tools))

# -- what an agent gets --------------------------------------------------
#
# Every one of these is a command an operator runs, and every one of
# them said `:read-only? true` where it is declared — in void/jobs, in
# void/db, in void/bus, three packages that know nothing about MCP.

(each name ["routes" "db_status" "db_erd" "jobs_stats" "jobs_list"
            "bus_stats" "bus_tail" "cache_stats" "obs_status" "obs_metrics"
            "authz_policies" "mail_status" "mcp_tools"
            # this application's own, and the only thing that put it
            # here is `:read-only? true` where it is declared
            # (src/app.janet)
            "shop_stock"]
  (assert (index-of name tools)
          (string "the shop exposes " name " — a read-only command of the composition")))

# -- and the desk, which nobody described twice --------------------------
#
# void/admin-mcp projects the same `defresource-admin` declarations the
# pages are projected from (src/modules/*/*.admin.janet), so a column
# added to an entity reaches the list, the form and the tool in one
# edit. Reading is offered; writing waits to be named.

(each name ["admin-products-list" "admin-products-get"
            "admin-orders-list" "admin-customers-list"
            "admin-audit-events-list"
            # `:mount false` is a declaration without a section, and it
            # is still a resource here: the lines and the payments of an
            # order have no page and are readable by whoever asks
            "admin-order-items-list" "admin-payments-list"]
  (assert (index-of name tools)
          (string "the shop exposes " name " — a read-only projection of a declaration")))

(each name ["admin-products-create" "admin-products-update"
            "admin-products-delete" "admin-products-archive"
            "admin-orders-ship" "admin-customers-update"]
  (assert (not (index-of name tools))
          (string "the shop withholds " name " — it changes something (ADR-0031)")))

# -- what it does not get ------------------------------------------------
#
# Nothing below is hidden by a list in this example's config: they are
# absent because each of them declared that it writes, and the default
# exposes nothing else. `shop/seed` is this application's own command
# and obeys the same rule.

(each name ["db_migrate" "db_rollback" "db_new" "jobs_work" "jobs_clear"
            "jobs_retry" "jobs_remove" "bus_publish" "bus_consume"
            "cache_clear" "cache_forget" "auth_token" "auth_sweep"
            "mail_send" "openapi_export" "shop_seed" "mcp_serve"]
  (assert (not (index-of name tools))
          (string "the shop withholds " name " — it changes something")))

# -- resources -----------------------------------------------------------

(def resources (exposed :resources))
(assert (index-of "void://health" resources) "the health report is readable")
(assert (index-of "void://metrics" resources)
        "and so is the exposition — void/mcp-obs is in the composition")
(each name ["Money" "ProductView" "OrderView"]
  (assert (index-of (string "void://schema/" name) resources)
          (string "the " name " DTO is a resource, because it is a registered schema")))

# the declaration itself is readable, which is how an agent learns what
# it may filter on, sort by and write without being told twice
(each name ["products" "orders" "payments"]
  (assert (index-of (string "void://admin/" name) resources)
          (string "the admin declaration of " name " is a resource")))

# -- and it is the same list `void mcp tools` prints ---------------------

(def out @"")
(with-dyns [:out out] (mcp/print-tools))
(assert (string/find "jobs_stats" out) "the report shows what is exposed")
(assert (string/find "shop_seed" out) "and names what is withheld")
(assert (string/find "declared that it writes" out) "with the reason")

(printf "  [shop] mcp: %d tools, %d resources exposed" (length tools) (length resources))
(print "mcp-test ok")
