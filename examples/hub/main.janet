### hub — entrypoint. Run the app with `void dev` (or
### `janet main.janet`); the void CLI (void routes, void repl, ...)
### reads the app binding below.
###
### Two things are chosen by environment, and each is one line:
###
###   VOID_HUB_DB=postgres      the driver (sqlite by default)
###   VOID_HUB_STORAGE=s3       delivery bodies in a bucket (a
###                             directory by default)
###
### Everything else is identical between a laptop and the compose file in
### ./docker-compose.yml. Both switches are the same switch really:
### `[:deploy :shape] :fleet` asks every store whether a second replica
### would see its contents, and a file on one container's disk is the one
### answer this application would otherwise get wrong.
(import void/cli :as cli)
(import void/http)
(import void/html)
(import void/htmx)
# the sign-in `void make auth` generated. Importing a plugin's module is
# what registers its manifest, which is what makes the keyword below
# resolvable — ./auth names void/auth and void/auth-http itself, and the
# rest of these it does not
(import void/db)
(import void/db/http)
(import void/db-sqlite)
(import void/crypto)
(import void/auth)
(import void/auth/http)
(import void/auth/db)
(import void/authz)
(import void/authz/http)
(import void/security)
(import void/mail)
(import void/mail/auth)
# the receiving end: the bytes go to a store, and the burst they arrive
# in is what void/pressure is for
(import void/storage)
(import void/storage/http)
(import void/obs)
(import void/obs/http)
(import void/pressure)
(import void/pressure/http)
# and the sending end: a queue in the same database as the deliveries,
# notifications over it, and the TLS an https bot API needs
(import void/jobs)
(import void/jobs/db)
(import void/notify)
(import void/notify/jobs)
(import void/tls)
# the operator's half: the desk, and the section of it that shows the
# queue this application's notifications go through
(import void/admin)
(import void/admin/jobs)
(import void/dev)
# and this application: one plugin, whose manifest is src/app.janet and
# whose code is the modules that file imports
(import ./src/app)

(def databases
  ``The `:void/db-driver` plugin per database. sqlite is imported at the
  top of this file — it is the laptop's default and the driver `jpm
  build` links into a binary — while postgres is *required* here, so a
  process that never speaks to one never opens libpq at all.``
  {:sqlite (fn [] :void/db-sqlite)
   :postgres (fn [] (require "void/db-postgres/init") :void/db-postgres)})

(defn- bucket-plugins
  ``The bucket, when this deployment has one. Required rather than
  imported for the reason the driver is: a laptop keeping delivery
  bodies in ./storage never loads a signer. void/tls is imported
  regardless — the telegram channel needs it whatever the store is
.``
  []
  (require "void/storage/s3")
  [:void/storage-s3])

(defn plugins
  ``The composition, as a function of the two things a deployment
  changes and the profile it runs under.

  void/dev is a dev-time plugin: it serves a repl and watches the tree,
  and it builds that repl's environment with `require` — which a single
  binary has no source tree to require from (docs/DEPLOY.md). So the
  production composition is this one without it, and dropping a plugin
  from a list is the whole of the change.``
  [profile &opt opts]
  (default opts {})
  (def database (get opts :database :sqlite))
  (def load-driver
    (or (databases database)
        (errorf "unknown database %q (known: %s)" database
                (string/join (map string (sorted (keys databases))) " "))))
  (filter
    |(or (not= :void/dev $) (not= :prod profile))
    [:void/http :void/html :void/htmx
     # data, and the one driver this deployment names: the library sqlite
     # needs is janet-lang/sqlite3, which the void bundle deliberately
     # does not carry — hence the second line in ./project.janet
     # void/db-http is two things this application asks of the same
     # plugin: the transaction the admin's writing routes declare with
     # `:void.db/txn`, and the session store a fleet needs — a session in
     # a process's heap is a login that works on one replica
     :void/db :void/db-http (load-driver)
     # every hash and every one-time code is minted in void/crypto; the
     # identity, the session and the stores read the tables ./auth
     # declared; void/security is the CSRF token the forms already carry
     :void/crypto
     :void/auth :void/auth-http :void/auth-db
     # who is asking is void/auth's answer; what they may do is
     # void/authz's, and the two never import each other — the identity
     # travels on a dyn key. `[:admin :access] :hub/operator` is the one
     # line that opens the desk, and ./admin.janet is where that policy is
     # written
     :void/authz :void/authz-http
     :void/security
     # a challenge nobody delivered is an error rather than a link into
     # the void, so the deliverer is part of the composition and not an
     # afterthought
     :void/mail :void/mail-auth
     # the raw body of every delivery, kept verbatim: a disk directory on
     # a laptop, a bucket where there is more than one replica
     :void/storage
     # ...and the route that hands those bytes back is the disk store's
     # half of the contract, so it is composed with it: void/storage-http
     # serves the local root under `[:storage :serve :signed] true`, and
     # with a bucket behind the contract the same link is S3's own query
     # auth, minted by the store and pointed at the bucket. A deployment
     # on a bucket that also mounted this route would be publishing a
     # directory it does not use
     ;(if (get opts :bucket) (bucket-plugins) [:void/storage-http])
     # deliveries arrive in bursts — a push to a busy repository
     # is a dozen events in a second — and shedding is the
     # difference between a slow hub and a dead one.
     #
     # void/obs-http is here for the endpoint the other end of that
     # sentence needs: /health is what an orchestrator asks, and
     # void/pressure-http never sheds it — so the answer arrives
     # *while* the process is refusing everything else, which is
     # exactly when it is being asked. /metrics comes with it, behind a
     # token
     :void/obs :void/obs-http
     :void/pressure :void/pressure-http
     # the queue lives in the same database as the deliveries, which is
     # what lets a delivery and the work it caused commit together
     :void/jobs :void/jobs-db
     # one event, however many channels the composition holds — here
     # exactly one, and it is this application's own. :void/notify-jobs
     # is what moves delivery off the request fiber: a job per channel,
     # retried with the value the request projected
     :void/notify :void/notify-jobs
     # api.telegram.org is https, and outgoing TLS is a plugin rather than
     # an assumption
     :void/tls
     # the desk. void/admin projects ./admin.janet's one
     # declaration into routes; void/admin-jobs brings the
     # section that shows the queue — which is this
     # application's main screen rather than a demo of one
     #
     :void/admin :void/admin-jobs
     :void/dev
     :hub/app]))

(defn database
  ``Which database this process boots on: `:sqlite` (the default — a
  file, nothing to install) or `:postgres`. `VOID_HUB_DB=postgres void
  dev` is the whole of the change; the connection itself is
  config/<profile>.janet, or the VOID_DB_POSTGRES__URL the compose file
  passes.``
  []
  (keyword (or (os/getenv "VOID_HUB_DB") "sqlite")))

(defn bucket?
  ``Whether delivery bodies live in a bucket. Off on a laptop (a
  directory, nothing to install), on in the compose file — where the
  web tier is more than one process, and a body written to one
  replica's disk is a 404 on the next for the operator who came to read
  it.``
  []
  (truthy? (let [v (os/getenv "VOID_HUB_STORAGE")]
             (and v (= "s3" (string/ascii-lower v))))))

(defn profile
  "The profile this process runs under."
  []
  (keyword (or (os/getenv "VOID_PROFILE") "dev")))

(def app
  ``Boot options — what (void/run! ...) starts and what the void CLI
  reads when it loads this module out of a source tree (`void routes`,
  `void db migrate`, `void hub replay`).

  `main` builds its own rather than using this one, and the difference
  is the single binary: `jpm build` marshals every *value* on the
  machine that builds, so an `os/getenv` in a `def` would be the
  environment of the build machine frozen into the executable
  (docs/DEPLOY.md rule 1). Here it is read on the machine that runs.``
  {:plugins (plugins (profile) {:database (database) :bucket (bucket?)})
   :profile (profile)})

(defn main [& args]
  # Every one of these is read *now*, in the process that is starting,
  # rather than in a value a build would have frozen.
  (def prof (profile))
  # cli/app-main runs the app when there are no arguments and is the
  # `void` binary when there are — so `./build/hub db migrate`
  # works on a target with no janet and no source tree, against exactly
  # the composition inside this executable (docs/DEPLOY.md).
  (cli/app-main {:plugins (plugins prof {:database (database) :bucket (bucket?)})
                 :profile prof}
                ;(drop 1 args)))
