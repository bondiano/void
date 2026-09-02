### hub — entrypoint. Run the app with `void dev` (or
### `janet main.janet`); the void CLI (void routes, void repl, ...)
### reads the app binding below.
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
(import void/pressure)
(import void/pressure/http)
# and the sending end: a queue in the same database as the deliveries,
# notifications over it, and the TLS an https bot API needs (ADR-0038)
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
(import ./admin)
(import ./auth)
(import ./ops)
(import ./route)
(import ./telegram)
(import ./intake)

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins [:void/http :void/html :void/htmx
             # data, and the one driver this application opts into: the
             # library it needs is janet-lang/sqlite3, which the void
             # bundle deliberately does not carry (ADR-0011) — hence the
             # second line in ./project.janet
             # void/db-http is the transaction the admin's writing
             # routes declare with `:void.db/txn` — a route says it
             # runs in one, and this is what opens it
             :void/db :void/db-http :void/db-sqlite
             # every hash and every one-time code is minted in
             # void/crypto (ADR-0022); the identity, the session and the
             # stores read the tables ./auth declared; void/security is
             # the CSRF token the forms already carry (ADR-0025)
             :void/crypto
             :void/auth :void/auth-http :void/auth-db
             # who is asking is void/auth's answer; what they may do is
             # void/authz's, and the two never import each other — the
             # identity travels on a dyn key (ADR-0024). `[:admin
             # :access] :hub/operator` is the one line that opens the
             # desk, and ./admin.janet is where that policy is written
             :void/authz :void/authz-http
             :void/security
             # a challenge nobody delivered is an error rather than a
             # link into the void (ADR-0023 §7), so the deliverer is
             # part of the composition and not an afterthought
             :void/mail :void/mail-auth
             # the raw body of every delivery, kept verbatim: a disk
             # directory here, a bucket where there is more than one
             # replica (ADR-0030, ADR-0039). void/storage-http is what
             # hands those bytes back — under `[:storage :serve
             # :signed] true`, so the prefix is private and a link
             # ./admin.janet minted is the only way in
             :void/storage :void/storage-http
             # deliveries arrive in bursts — a push to a busy repository
             # is a dozen events in a second — and shedding is the
             # difference between a slow hub and a dead one
             :void/pressure :void/pressure-http
             # the queue lives in the same database as the deliveries,
             # which is what lets a delivery and the work it caused
             # commit together (ADR-0012)
             :void/jobs :void/jobs-db
             # one event, however many channels the composition holds —
             # here exactly one, and it is this application's own
             # (ADR-0040). :void/notify-jobs is what moves delivery off
             # the request fiber: a job per channel, retried with the
             # value the request projected
             :void/notify :void/notify-jobs
             # api.telegram.org is https, and outgoing TLS is a plugin
             # rather than an assumption (ADR-0038)
             :void/tls
             # the desk. void/admin projects ./admin.janet's one
             # declaration into routes; void/admin-jobs brings the
             # section that shows the queue — which is this
             # application's main screen rather than a demo of one
             # (ROADMAP 6.6)
             :void/admin :void/admin-jobs
             :void/dev
             :hub/admin :hub/auth :hub/intake :hub/route :hub/telegram
             :hub/ops]})

# void/dev is a dev-time plugin: it serves a repl and watches the tree,
# and it builds that repl's environment with `require` — which a single
# binary has no source tree to require from (docs/DEPLOY.md). So the
# production composition is this one without it, and dropping a plugin
# from a list is the whole of the change.
(defn plugins
  "The composition for a profile."
  [profile]
  (if (= :prod profile)
    (filter |(not= :void/dev $) (app :plugins))
    (app :plugins)))

(defn main [& args]
  # The profile is read here rather than in `app` above: `jpm build`
  # marshals this file's values into the executable, so anything a
  # value computes is computed once, on the machine that built it.
  (def profile (keyword (or (os/getenv "VOID_PROFILE") "dev")))
  # cli/app-main runs the app when there are no arguments and is the
  # `void` binary when there are — so `./build/hub db migrate`
  # works on a target with no janet and no source tree, against exactly
  # the composition inside this executable (docs/DEPLOY.md).
  (cli/app-main {:plugins (plugins profile) :profile profile} ;(drop 1 args)))
