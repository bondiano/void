# shop — the config layer every profile shares (void/core/config:
# plugin defaults <- default.janet <- <profile>.janet <- VOID_* env
# vars <- CLI overrides; `void config explain :cache :ttl` shows where
# a value came from).

{# Three components provide :void/jobs-backend once void/jobs-db is in
 # the composition, and the kernel refuses to guess: the queue lives in
 # the database, next to the data it is bookkeeping for — which is what
 # lets a payment capture be enqueued by the same transaction that
 # wrote the order.
 :void/jobs-backend {:impl :jobs/db}

 # A cart belongs to a browser before it belongs to an account, and the
 # session is where the browser keeps its handle on one. In-process is
 # right for one process and wrong for anything past it — a second
 # prefork worker and a second machine break it identically, which is
 # why the check is on the deployment shape rather than on [:http
 # :workers] (ADR-0030). config/prod.janet is where this deployment
 # says it is a fleet and names the shared store for every one of
 # these. The [:http] slice itself is below, next to the static files.

 :db {:migrations {:dir "db/migrations"}}

 # The stylesheet, served straight out of the source tree in
 # development ([:html :assets] passthrough) and out of the
 # fingerprinted build after `assets/build!` — the markup is
 # `(html/asset "shop.css")` either way (src/web/layout.janet).
 :http {:session {:enabled true}
        :static {:root "assets" :prefix "/assets/"}}

 # the catalog is read on every page and written by nobody but an
 # operator, which is the shape a cache is actually for
 :cache {:prefix "shop:" :ttl 60}

 # -- product pictures ---------------------------------------------------
 #
 # A directory next to the checkout, served by void/storage-http under
 # /uploads with the same ETag and Range handling the stylesheet gets
 # (ADR-0039). This is the right store for one process and the wrong
 # one for anything past it, exactly like the in-memory session store
 # above: config/prod.janet moves it into the minio bucket, and a
 # deployment that forgets does not start ([:deploy :shape] :fleet,
 # ADR-0030).
 #
 # The prefix is public: a product picture is on a page anybody can
 # open. `[:storage :serve :signed] true` would make every URL a
 # temporary signed one, which is what a receipt or an invoice needs.
 :storage {:local {:root "storage"}
           :serve {:prefix "/uploads"}}

 # -- who is asking ------------------------------------------------------
 #
 # Three interfaces have two implementations each — the memory stores
 # void/auth ships and the database ones void/auth-db does — and the
 # kernel refuses to guess. The database ones, because a magic-link code
 # issued by one process has to be redeemable at another, and an API
 # token minted by the CLI has to work in the web tier.
 :void/auth-user-store {:impl :auth.db/users}
 :void/auth-token-store {:impl :auth.db/tokens}
 :void/auth-challenge-store {:impl :auth.db/challenges}

 # void/auth-db reads the table this application already had. The
 # plugin reads a users table; it does not own one.
 :auth-db {:users {:table "customers"
                   :id-column "id"
                   :subject-kind "customer"
                   :email-column "email"
                   :password-column "password_hash"
                   # `name` so a page can greet somebody without a
                   # second query, and `role` because it is the whole
                   # of this shop's RBAC: void/authz reads it back as
                   # `:subject/role` and `(authz/role-policy :staff)`
                   # is what the admin routes name
                   :claims-columns ["name" "role"]}}

 # One process serves a storefront and a JSON API, and this is the
 # line where that costs something: `:status` answers an
 # unauthenticated request with a 401 (rendered as problem+json for
 # the API, as an error page for the browser), where a browser-only
 # application would say `:redirect` and send the visitor to
 # `:login-path`. A shop that had no API would flip this one word —
 # the storefront never sends a signed-out visitor to a protected
 # page anyway, because the nav does not draw the links.
 :auth-http {:unauthenticated :status :status 401 :login-path "/sign-in"}

 # Every route this application owns names a policy — grep the
 # controllers under src/modules/ and there is no exception, `:public`
 # included.
 #
 # It is `:allow` here anyway, and that is a fact about the
 # composition rather than about the posture. Under `[:authz :default
 # :deny]` a route with no `:void.authz/policy` fails the boot
 # (ADR-0024 §6) — and this process serves five routes it did not
 # write: `/metrics`, `/health`, `/ready` from void/obs-http and
 # `/openapi.json`, `/docs` from void/openapi. Route metadata can only
 # be set by whoever declares the route, so there is no line an
 # application can write to mark somebody else's route public, and
 # `:deny` would refuse to start over routes that are open by design.
 # examples/blog, which composes neither plugin, takes the `:deny`
 # posture and is where that gate is demonstrated.
 :authz {:default :allow}

 # -- mail ---------------------------------------------------------------
 #
 # In development every letter is written into tmp/mail as a .eml —
 # open one and it renders in a mail client. In production this has to
 # be :smtp (or a transport the application contributes): a transport
 # that keeps mail rather than sending it is a boot error in the :prod
 # profile, because a deployment that silently mails nothing looks
 # exactly like one that works (ADR-0026 §2).
 #
 # :base-url is not optional decoration — a letter has no origin, so
 # the link in it must be absolute, and a relative one is an error at
 # render time rather than a dead link in an inbox.
 :mail {:transport :file
        :from "void shop <no-reply@shop.example>"
        :base-url "http://localhost:8080"}

 # Three queues, because they fail differently. A payment capture that
 # is retrying must not hold up the receipt; a receipt that a relay is
 # refusing must not hold up the nightly sweep.
 :jobs {:queues {:payments {:concurrency 2}
                 :mail {:concurrency 2}
                 :maintenance {:concurrency 1}}}

 # -- the bus ------------------------------------------------------------
 #
 # The bus lives in the same database as the data, which is the whole
 # reason `bus/publish-tx!` is possible: `order/placed` and the order
 # row commit in one transaction (ADR-0012). Nothing outside this
 # process consumes these messages, so :codec :jdn rather than the
 # default :json — jdn round-trips a keyword. An application whose
 # events are read by a second service leaves the default alone, which
 # is why it is the default.
 :bus {:backend :db :group :shop :codec :jdn}

 # -- what a browser is allowed to do ------------------------------------
 #
 # The default CSP is `default-src 'self'` and nothing else, which is
 # the right default and exactly two lines short of what this
 # application needs: htmx comes from a CDN, and so do the Swagger UI
 # assets void/openapi serves under /docs. The policy is data, so
 # naming that origin is a key rather than a string to get wrong — an
 # unknown directive here is a boot error, not a header nobody reads.
 # The rate limiter is off until a deployment turns it on, because a
 # guessed limit is either useless or an outage (void/security's
 # defaults say so). This one is on with **no `:global`**: only the
 # routes that name `:void.security/rate` are limited — the sign-in
 # forms, the checkout and the JSON API — and everything else is
 # unmetered. The counter is in this process's memory; config/prod
 # moves it to the cache, which is redis there, because a limit that
 # each worker counts separately is a limit multiplied by the number
 # of workers.
 :security {:rate {:enabled true}
            :csp {:policy {:default-src [:self]
                           :script-src [:self "https://unpkg.com"]
                           :style-src [:self "https://unpkg.com"]
                           :base-uri [:self]
                           :form-action [:self]
                           :frame-ancestors [:none]
                           :object-src [:none]
                           # product pictures come from this origin in
                           # development (void/storage-http serves them
                           # under /uploads) and from the bucket in the
                           # compose file — config/prod.janet adds that
                           # origin, because a picture a policy blocks
                           # is a picture that silently does not draw
                           :img-src [:self "data:"]}}}

 # -- the desk -----------------------------------------------------------
 #
 # The admin is shut by default and this key is what opens it: it names
 # the policy that decides who is an operator, and the shop already had
 # one — `:staff`, over the `role` column on customers
 # (modules/customers/customers.policy). No second authentication, no
 # separate session, no admin user table: a member of staff is a
 # customer with a role, and this line is the whole of saying so
 # (ADR-0029 §3).
 :admin {:access :staff
         :title "void shop — the desk"
         # every route void/admin projects carries these. The document
         # void/openapi builds is a projection of the *route table*,
         # and the back office is not part of the shop's public API —
         # so one key here keeps thirty admin routes out of it, and
         # `test/api-test.janet` checks that it does
         :route-meta {:void.openapi/hidden true}}

 # -- the API document ---------------------------------------------------
 :openapi {:info {:title "void shop"
                  :version "1.0.0"
                  :description "The JSON half of the shop: the catalog, and the orders of whoever holds the token."}}}
