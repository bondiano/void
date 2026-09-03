# hub — the layer every profile starts from (void/core/config: plugin
# defaults <- this file <- config/<profile>.janet <- VOID_* env vars <-
# CLI overrides; `void config explain :mail :transport` says which one
# won).
#
# Everything here is what `void make auth` printed when it generated
# ./auth.janet — the three stores, the columns void/auth-db reads out
# of the application's own table, and where an unauthenticated request
# is sent. It is configuration rather than code because none of it is a
# decision this application makes twice.
{:http {:session {:enabled true}
        # What a *page* is allowed to post. GitHub caps a delivery at
        # 25 MiB and this application has to read the ones it is sent,
        # but that is one route's business: `[:http :max-body]` is what
        # a route that declares nothing gets, not a ceiling over the
        # ones that do — `:void.http/max-body` is `:restrict` between
        # *metadata* layers (group -> route), and the intake route sits
        # under no group that names one. So the number that is true of
        # almost every route lives here and the exception says so on
        # itself (./intake.janet)
        :max-body 65536}

 :db-sqlite {:path "db/hub.sqlite3"}

 # two components provide :void/jobs-backend — the memory queue void/jobs
 # ships and the database one void/jobs-db does — and the kernel refuses
 # to guess between them. The queue goes in the database, because a
 # notification that a delivery caused should be committed with the
 # delivery
 :void/jobs-backend {:impl :jobs/db}

 # void/notify-jobs puts its work on the `:notify` queue, and a worker
 # runs the queues it was told about — a queue nobody named is a queue
 # that fills up while `void jobs work` reports nothing to do
 :jobs {:queues {:notify {:concurrency 2}}}

 # where a delivery's bytes are kept. A directory on one machine; the
 # bucket is what `[:deploy :shape] :fleet` will ask for the moment there
 # is a second replica
 #
 # `:serve :signed` turns the whole prefix private: every GET under
 # /storage has to carry the `exp`/`sig` pair a temporary URL minted, and
 # an expired or edited link is a 403 that does not say which it was. This
 # application stores exactly one kind of object — somebody else's webhook
 # payload — so there is nothing here that should be public, and the
 # deliveries page hands out five-minute links instead (./admin.janet)
 #
 # `:policy :public` is the other half of saying that out loud: the
 # signature *is* the authorization on this prefix, so the route is
 # open to whoever holds a link and says so with a policy name rather
 # than with silence — which is the difference a `[:authz :default]
 # :deny` composition would need and this one writes down anyway
 :storage {:local {:root "storage"}
           :serve {:signed true
                   :policy :public}}

 # The sources this hub receives from: a name that appears in the path
 # and the secret the sender signs with. Nothing is configured by
 # default — an endpoint nobody set up answers 404 rather than accepting
 # anonymous bytes — and a deployment adds one:
 #
 #     :hub {:sources {:github {:signing-secret
 #                              {:secret "GITHUB_WEBHOOK_SECRET"}}}}
 #
 # `{:secret "NAME"}` is a **reference**, not the value: void/core/config
 # resolves it from that environment variable at load and hands the
 # application an opaque box, so the secret is in no printed config and
 # no log line (./intake.janet, `signing-secret`)
 # Rules say where a delivery goes, and they are data rather than a
 # branch (./route.janet): `:when` is a conjunction over the row's own
 # fields, a field a rule does not mention is one it does not care
 # about, and every matching rule is its own notification. A deployment
 # writes its own; the shape is
 #
 #     :rules [{:when {:event ["push" "release"] :repo "bondiano/void"}
 #              :to [:telegram]
 #              :chat-id "-1001234567890"}]
 #
 # The bot itself is [:hub :telegram]: `{:token {:secret "TELEGRAM_BOT_TOKEN"}
 # :chat-id "..."}` — the chat here is the one a rule does not name.
 #
 # `:operators` is who may read what was received: the addresses that
 # get past `:hub/operator` (./admin.janet) and into the desk. Empty
 # here, which means nobody — registration on this application is open,
 # and "anybody signed in is staff" over an open registration is a hub
 # anybody can read. A deployment names its own:
 #
 #     VOID_HUB__OPERATORS='["ada@example.com"]'
 #
 # (the environment layer parses a JDN value, so a list is a list)
 :hub {:sources {}
       :rules []
       :telegram {}
       :operators []}

 # the three stores void/auth resolves by name: people, API tokens and
 # the single-use codes a challenge mints. All three are void/auth-db's,
 # which is to say: rows in the database this application already has
 :void/auth-user-store {:impl :auth.db/users}
 :void/auth-token-store {:impl :auth.db/tokens}
 :void/auth-challenge-store {:impl :auth.db/challenges}

 # which columns of ./auth's `users` mean what. void/auth-db reads them
 # and never writes, so registration stays a handler in the application
 :auth-db {:users {:table "users"
                   :subject-kind "user"
                   :email-column "email"
                   :password-column "password_hash"
                   :claims-columns ["email"]}}

 # a browser gets a redirect to the sign-in page, not a 401 body
 :auth-http {:unauthenticated :redirect :login-path "/login"}

 # One host, and it is the only widening in this file. The page
 # `void new` writes loads htmx from unpkg, and the moment
 # `void make auth` puts void/security in the composition the default
 # policy (`default-src 'self'`) stops it — a page whose script the
 # browser refuses and says so only in its console. `void make auth`
 # now prints this block for exactly that reason; it used to be
 # folklore, and this application is where that was found.
 #
 # `:policy` replaces the defaults rather than merging into them (a
 # policy is one value, and half a policy is a different policy), so
 # what is written out here is void/security's own default plus the one
 # host — see security/void/security/csp.janet.
 #
 # There is no `:style-src` line: void/admin serves its stylesheet as a
 # fingerprinted file from its own prefix rather than writing it into
 # the page, so composing the back office costs this application
 # nothing. It cost `'unsafe-inline'` until the hub said so.
 :security {:csp {:policy {:default-src [:self]
                           :script-src [:self "https://unpkg.com"]
                           :base-uri [:self]
                           :form-action [:self]
                           :frame-ancestors [:none]
                           :object-src [:none]
                           :img-src [:self "data:"]}}}

 # The desk. `:access` names the policy that decides who is an operator
 # and is the whole of opening it — without this line every admin route
 # refuses everybody, which is the right default for a back office and the
 # reason there is no default value.
 #
 # `:route-meta` is what this application says about *its* admin's
 # routes, as group metadata:
 #
 #   :void.auth/access :required — an operator who is not signed in gets
 #     the sign-in page and comes back to where they were going, rather
 #     than a 403 with nothing to do about it. The key is `:restrict`,
 #     so no admin route can loosen it
 :admin {:access :hub/operator
         :title "hub"
         :route-meta {:void.auth/access :required}}

 # the one route a letter points at: `challenge!` mints the code, the
 # deliverer builds this URL, and which flow it was for travels on the
 # challenge rather than in the path
 :mail-auth {:link-path "/auth/link"}

 :mail {:from "hub <no-reply@hub.example>"}}
