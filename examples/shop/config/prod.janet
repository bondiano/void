### shop :prod profile — the deployment in docker-compose.yml.
###
### Everything here is either a fact about that deployment (where the
### database is, that there is a relay next to the process) or a
### posture the :dev profile has no business taking. Connection details
### themselves are **not** here: they arrive as VOID_* environment
### variables, which is the layer above this file (ADR-0007), so one
### image runs against any database without a rebuild.

{:http {# a container answers on the interface the network gave it, not
        # on loopback
        :host "0.0.0.0"
        :port 8080
        # sessions in redis, which is what lets the web tier be more
        # than one process (ADR-0010): an in-memory store plus prefork
        # workers is a login that works every other request, and
        # void/http refuses that combination at :start
        :session {:store :redis :ttl 86400}}

 # the CSRF token, the session cookie and every signature in
 # void/security stand on this. It is a secret reference: the value
 # lives in the environment, and the config tree holds an opaque box
 # that does not print (ADR-0007 §5). Without it the process refuses to
 # start in :prod — an ephemeral key would sign tokens the next
 # deployment rejects
 :security {:signing-key {:secret "SHOP_SECRET_KEY"}
            # the rate limiter counts in the shared cache (redis, three
            # lines down), so the limit is the limit however many web
            # processes there are
            :rate {:store :cache}
            # behind a reverse proxy the client address is computed
            # from the chain, never read from a header anybody can send
            :trusted-proxies ["10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"]}

 # the shared cache, so two web processes agree about the catalog and
 # about the rate limiter's counters. Two components provide
 # :void/cache-store once void/cache-redis is composed, and the kernel
 # refuses to guess which — the same shape [:void/jobs-backend] has
 :void/cache-store {:impl :cache/redis}

 # a relay next to the application holds the TLS (ADR-0010); this
 # client speaks to it in the clear over the container network
 :mail {:transport :smtp}

 # the web tier serves and enqueues; the worker deployment is the same
 # image with the two switches flipped by environment variables
 # (docker-compose.yml), so neither is on here
 :jobs {:worker {:enabled false} :scheduler {:enabled false}}

 # The queue's tables and the message log's are created by a migration
 # this application owns (db/migrations/20261001090500), not by
 # whichever process boots first: two processes starting together race
 # on `CREATE INDEX IF NOT EXISTS`, and a schema that appears on its
 # own is a schema nobody reviewed.
 :jobs-db {:auto-create false}
 :bus-db {:auto-create false}

 # a container has a memory limit, which is the one number
 # void/pressure cannot guess (ADR-0019): 384 MB of the 512 the compose
 # file gives this service, so the process starts refusing before the
 # kernel starts killing
 :pressure {:max-rss-bytes 402653184}

 # void/dev is composed here too, and the two halves of it are not the
 # same decision. The file watcher polls the source tree twice a second
 # and nothing in a container ever changes on disk, so it is off. The
 # netrepl stays **on**: it listens on a unix socket inside the
 # container (`.void/repl.sock`), so reaching it means being able to
 # exec into the container already — and a REPL inside the running
 # process is one of the things void is for (SPEC §4).
 #
 #     docker compose exec web void repl
 :dev {:watch {:enabled false}
       :netrepl {:enabled true}}

 # /metrics is scraped by prometheus over the compose network and by
 # nobody else; the token is what makes "and by nobody else" true, and
 # it arrives as VOID_OBS_HTTP__TOKEN rather than being written here —
 # a bearer token in a file in the image is a token in the image
 :obs-http {:endpoints true}}
