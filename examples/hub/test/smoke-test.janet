### The composition in main.janet, booted and driven (ADR-0017).
###
### ./auth-test.janet is the generated suite, and it writes its own
### plugin list on purpose — it has to pass the moment it is generated,
### before anything has been added to main.janet. This one is the other
### half: it boots **main.janet's** list, so a plugin dropped from the
### application is a failing test rather than a page that quietly stops
### working.
###
### There is no test-support/paths.janet here and there will not be:
### this example imports void from an installed tree (../../README of
### the repository, scripts/install-tree.janet), which is the whole
### reason it exists.
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/jobs :as jobs)
# relative, because nothing puts this directory on module/paths: the
# other examples get theirs from test-support/paths.janet, which is the
# file this one does not have
(import ../main :as main)

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/hub-smoke-" (os/time) ".sqlite3"))

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{}
                   :cli {:http {:port 0}
                         :db {:migrations {:dir "db/migrations"}}
                         :db-sqlite {:path sqlite-path}
                         # letters go to a value this process can read,
                         # rather than to a directory or a network
                         :mail {:transport :memory}
                         # the cost of a hash is void/crypto's business
                         # and not this suite's (auth-test says the same)
                         :auth {:scrypt {:ln 10}}
                         :crypto {:kdf {:in-thread false}}
                         :dev {:netrepl {:enabled false}
                               :watch {:enabled false}}}}}))

(log/set-sinks! [(fn [_])])

# the composition is valid before anything starts: this is `void plugins
# check` as an assertion, and it is what catches an import removed from
# main.janet next to a keyword left in the list
(assert ((plugin/dry-run opts) :ok) "dry-run passes on main.janet's composition")

(test/with-http [c (merge opts {:only [:http/kernel :crypto/lib :auth/registry]})]
  (db/migrate-up! {:dir "db/migrations"})

  # -- the pages this application has ------------------------------------
  #
  # The guestbook `void new` wrote is gone: everything a person does
  # here is operations, so `/` is the queue and the desk is the rest
  # (../admin.janet). What that page does under a policy and a
  # signature is ./ops-test's; here it is only that the composition
  # still has a front door
  (def home (test/inject c {:uri "/"}))
  (assert (= 302 (home :status)))
  (assert (= "/admin/jobs" (get-in home [:headers "location"])))

  (def register (test/inject c {:uri "/register"}))
  (assert (= 200 (register :status)) "the generated sign-up page is mounted")
  (assert (string/find `name="_csrf"` (test/text register))
          "void/security binds the token the form asks for (ADR-0025)")

  # -- the identity is wired, not merely composed ------------------------
  (def guarded (test/inject c {:uri "/password/edit"}))
  (assert (= 302 (guarded :status))
          "a :required route without an identity redirects")
  (def location (get-in guarded [:headers "location"]))
  (assert (string/has-prefix? "/login?" location)
          "and it redirects to [:auth-http :login-path]")
  (assert (string/find "next=%2Fpassword%2Fedit" location)
          "carrying where it was going, so the sign-in can finish the trip")

  # -- the worker starts what this application's jobs need ---------------
  #
  # A command starts its `:needs` and nothing else, and `void jobs work`
  # needs the queue — which is true of the worker and not of the jobs.
  # This application's job is an https delivery, so somebody has to say
  # `:tls/lib`, or the composition holds void/tls unstarted while the
  # notification dies against "no libssl open". The thing that knows is
  # the channel (./telegram.janet); void/notify-jobs puts the union of
  # the active channels' needs on the delivery job and `void jobs work`
  # starts it. Live once, asserted from here on
  (assert (index-of :tls/lib (jobs/job-needs [:notify]))
          "the worker on the :notify queue opens the TLS stack the delivery needs")
  (assert (empty? (filter |(= :hub/work (get-in $ [:value :name]))
                          (get-in boot [:extensions :void.core/cli :contributions] [])))
          "...so this application no longer carries a worker command of its own")

  # -- the policy that lets the page load its script ---------------------
  #
  # `void new` writes a layout that loads htmx from unpkg and
  # `void make auth` puts void/security in the composition; the default
  # policy would refuse that script with nothing said on the terminal
  # (README, hand edit 3). The widening is config, so it is asserted
  # here rather than remembered
  (def csp (get-in register [:headers "content-security-policy"]))
  (assert (string/find "https://unpkg.com" csp)
          "the policy admits the host the generated page loads from")
  (assert (not (string/find "unsafe-inline" csp))
          "and nothing else is widened: void/admin serves its stylesheet rather than writing it into the page")
  (assert (string/find "frame-ancestors 'none'" csp)
          "and it is still void/security's default everywhere else"))

(os/rm sqlite-path)
(log/set-sinks! nil)
(print "hub smoke-test ok")
