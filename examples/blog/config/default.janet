# blog — the config layer every profile shares (void/core/config:
# plugin defaults <- default.janet <- <profile>.janet <- VOID_* env
# vars <- CLI overrides; `void config explain :cache :ttl` shows where
# a value came from).

{# Three components provide :void/jobs-backend once void/jobs-db is in
 # the composition, and the kernel refuses to guess: the queue lives in
 # the database, next to the data it is bookkeeping for.
 :void/jobs-backend {:impl :jobs/db}

 # -- what this application is deployed as --------------------------------
 #
 # One process. Saying so is what makes the rest of this file legal:
 # the session store, the cache and the rate limiter below all live in
 # this process's heap, and under `:fleet` — which is what the :prod
 # profile defaults to — void refuses to start with any of them
 # (ADR-0030). `void deploy check` prints the list.
 #
 # Turning this into a fleet is four lines, and they are all in this
 # file: {:http {:session {:store :db}}} with void/db-http composed,
 # {:void/cache-store {:impl :cache/redis}} with void/cache-redis,
 # {:security {:rate {:store :cache}}}, and the bus and queue are in
 # the database already. examples/shop is that application.
 :deploy {:shape :single}

 # Wave 3 signs people in, and a sign-in rides on a session. The store
 # is in-process, which is exactly as wrong for a second machine as it
 # is for a second prefork worker — one deployment shape, one check.
 :http {:session {:enabled true}}

 :db {:migrations {:dir "db/migrations"}}

 # The article list is cached for a minute and dropped on every write —
 # the recount job invalidates it too, because it is what makes the
 # counter change. `cache/forget` clears **the store the composition
 # resolved**, and this one is in this process's heap: with a second
 # replica the invalidation would clear one cache out of N and the
 # other replicas would keep serving the stale index until the TTL ran
 # out. That is why [:deploy :shape] above says :single, and why
 # {:void/cache-store {:impl :cache/redis}} is the line that changes it.
 :cache {:prefix "blog:" :ttl 60}

 # -- wave 3 -------------------------------------------------------------
 #
 # Three interfaces now have two implementations each — the memory
 # stores void/auth ships and the database ones void/auth-db does — and
 # the kernel refuses to guess (the same thing :void/jobs-backend does
 # above). The database ones, because a magic-link code issued by one
 # process has to be redeemable at another.
 :void/auth-user-store {:impl :auth.db/users}
 :void/auth-token-store {:impl :auth.db/tokens}
 :void/auth-challenge-store {:impl :auth.db/challenges}

 # void/auth-db reads the table this application already had. Nothing
 # about `authors` changed for it except one nullable column
 # (db/migrations/20260901120000): the plugin reads a users table, it
 # does not own one.
 :auth-db {:users {:table "authors"
                   :id-column "id"
                   :subject-kind "author"
                   :email-column "email"
                   :password-column "password_hash"
                   # the name is on the identity so a page can greet
                   # somebody without a second query; the policy in
                   # app.janet needs only the subject
                   :claims-columns ["name"]}}

 # A browser application: an unauthenticated request to a protected
 # route belongs on the sign-in page, not on a 401.
 :auth-http {:unauthenticated :redirect :login-path "/"}

 # Mail. In development every letter is written into tmp/mail as a
 # .eml — open one and it renders in a mail client, which is what the
 # sign-in link should be looked at in. In production this has to be
 # :smtp (or a transport the application contributes): a transport that
 # keeps mail rather than sending it is a boot error in the :prod
 # profile, because a deployment that silently mails nothing looks
 # exactly like one that works (ADR-0026 §2).
 #
 # :base-url is not optional decoration — a letter has no origin, so
 # the link in it must be absolute, and a relative one is an error at
 # render time rather than a dead link in an inbox.
 :mail {:transport :file
        :from "blog <no-reply@blog.example>"
        :base-url "http://localhost:8080"}

 # void/mail-jobs is in the composition, so mail/send hands the
 # rendered letter to the queue and `void jobs work` sends it. The
 # queue is the same one the counter job runs in.
 :jobs {:queues {:maintenance {:concurrency 2}
                 :mail {:concurrency 2}}}

 # -- wave 3.6 -----------------------------------------------------------
 #
 # The bus lives in the same database as the data, which is the whole
 # reason `bus/publish-tx!` is possible: the audit message and the row
 # it is about commit in one transaction (ADR-0012). :group is this
 # application's default consumer group; ./audit reads under its own
 # (:audit), so a slow trail never holds up the counter job.
 #
 # :codec :jdn rather than the default :json — nothing outside this
 # process consumes these messages, and jdn round-trips a keyword. An
 # application whose events are read by a second service leaves the
 # default alone, which is why it is the default.
 :bus {:backend :db :group :blog :codec :jdn}

 # Every route that is not explicitly public has to name a policy, and
 # a route that forgets one fails the *boot* rather than the request
 # (ADR-0024 §6). This is the posture an application takes on purpose.
 :authz {:default :deny}

 # The back office (ADR-0029). One line opens it, and the line names a
 # policy rather than saying `true`: until it is here, every admin
 # route refuses everybody, including the person who just deployed it.
 # `:blog/staff` is defined in ./admin.janet, which is also the only
 # place to edit to narrow it.
 :admin {:access :blog/staff
         :title "blog admin"}}
