# blog — the config layer every profile shares (void/core/config:
# plugin defaults <- default.janet <- <profile>.janet <- VOID_* env
# vars <- CLI overrides; `void config explain :cache :ttl` shows where
# a value came from).

{# Three components provide :void/jobs-backend once void/jobs-db is in
 # the composition, and the kernel refuses to guess: the queue lives in
 # the database, next to the data it is bookkeeping for.
 :void/jobs-backend {:impl :jobs/db}

 # Wave 3 signs people in, and a sign-in rides on a session. The store
 # is in-process, which is right for one process and wrong for prefork
 # workers (ADR-0010) — void/http refuses that combination at :start
 # rather than losing every other login, and the fix is :redis.
 :http {:session {:enabled true}}

 :db {:migrations {:dir "db/migrations"}}

 # the article list is cached for a minute and dropped on every write —
 # the recount job invalidates it too, because it is what makes the
 # counter change
 :cache {:prefix "blog:" :ttl 60}

 :jobs {:queues {:maintenance {:concurrency 2}}}

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

 # Every route that is not explicitly public has to name a policy, and
 # a route that forgets one fails the *boot* rather than the request
 # (ADR-0024 §6). This is the posture an application takes on purpose.
 :authz {:default :deny}}
