### hub :prod profile — the deployment in docker-compose.yml.
###
### Everything here is either a fact about that deployment (that there is
### more than one replica, that a proxy holds the TLS, that the bucket is
### where bodies go) or a posture the :dev profile has no business taking.
### Connection details themselves are **not** here: they arrive as VOID_*
### environment variables, which is the layer above this file, so one
### image runs against any database and any bucket without a rebuild.

{# What this is deployed as, said out loud. :fleet is already
 # the :prod default — it is written here because everything below is
 # the answer to it, and because `void deploy check` prints the reason
 # it was given: "the compose file runs a web tier that scales and a
 # worker beside it" is a better reason than "the profile said so".
 :deploy {:shape :fleet}

 :http {# a container answers on the interface the network gave it, not
        # on loopback
        :host "0.0.0.0"
        :port 8080
        # sessions in the database this application already has. The
        # other shared answer is :redis (void/redis-http), and this
        # deployment does not run one — the queue is in this database
        # too, and a second server for one table is a second thing to
        # operate. The table is a migration of ours rather than the
        # plugin's boot-time DDL, three lines down
        :session {:store :db :ttl 86400}}

 # the web tier and the worker start together, and two processes racing
 # on `CREATE TABLE IF NOT EXISTS` is an error one of them gets. Both
 # tables are created by migrations this application owns
 # (db/migrations/), out of the DDL the plugins ship as data
 :db-http {:session {:auto-create false}}
 :jobs-db {:auto-create false}

 # the CSRF token, the session cookie and every signature void/security
 # mints stand on this. It is a secret reference: the value lives in the
 # environment and the config tree holds an opaque box that does not
 # print. Without it the process refuses to start in :prod — an ephemeral
 # key would sign tokens the next deployment rejects.
 #
 # `:trusted-proxies` is the other half of running behind Caddy: the
 # client address is computed from the forwarded chain, and only for
 # requests that arrived from an address in this list — a header
 # anybody can send is not an identity. The range is the compose
 # network's; a deployment behind somebody else's load balancer names
 # that one instead.
 #
 # There is no `:rate` here, and that is a decision rather than an
 # omission: a rate limiter shared by two replicas counts in a cache, and
 # the only shared cache void has is redis — the server this deployment
 # does not run. What a hub is actually flooded with is deliveries, and
 # those are shed by void/pressure below, which measures this process
 # rather than counting for the fleet.
 :security {:signing-key {:secret "HUB_SECRET_KEY"}
            :trusted-proxies ["172.16.0.0/12" "10.0.0.0/8" "192.168.0.0/16"]}

 # -- delivery bodies, in a bucket ---------------------------------------
 #
 # Two components provide :void/storage-store once void/storage-s3 is
 # composed (VOID_HUB_STORAGE=s3 in the compose file), and the kernel
 # refuses to guess. The disk store is what `void deploy check` refuses
 # here: a body written to one replica's disk is a 404 for the operator
 # who came to read it on another, and the container that gets replaced
 # takes the evidence with it.
 #
 # The endpoint, the bucket and the region arrive as VOID_STORAGE_S3__*
 # variables, so the same image runs against minio in the compose file
 # and against S3 or R2 without a rebuild. The bucket stays **private**:
 # unlike the shop's product pictures, every object here is somebody
 # else's payload, and the link the desk hands out is SigV4 query auth
 # good for five minutes.
 :void/storage-store {:impl :storage/s3}

 # The credentials are the one part of the connection written here rather
 # than passed as a plain VOID_* variable, for the reason HUB_SECRET_KEY
 # is: a secret reference resolves out of the environment into a box that
 # does not print, so a credential cannot reach a log line or a `void
 # config explain`. The key is spelled :secret-key and not :secret — a
 # slice key called :secret *is* the env-reference form, and the literal
 # would be read as one.
 :storage-s3 {:access-key {:secret "S3_ACCESS_KEY"}
              :secret-key {:secret "S3_SECRET_KEY"}}

 # a relay next to the application holds the TLS; this client speaks to it
 # in the clear over the container network. The address is
 # VOID_MAIL__SMTP__HOST, and a deployment that is not a demo points it at
 # a real relay rather than at the compose file's inbox
 :mail {:transport :smtp}

 # the web tier serves and enqueues; the worker is the same image with
 # one switch flipped by an environment variable (docker-compose.yml),
 # so it is off here
 :jobs {:worker {:enabled false}}

 # /health and /ready are what the compose file's healthcheck and the
 # proxy read, and void/pressure-http exempts them from shedding, so they
 # answer while the process is refusing deliveries. /metrics answers a
 # bearer token and nothing else; the token arrives as
 # VOID_OBS_HTTP__TOKEN rather than being written here — a token in a file
 # in the image is a token in the image
 :obs-http {:endpoints true}

 # a container has a memory limit, which is the one number void/pressure
 # cannot guess: 384 MB of the 512 the compose file gives each service, so
 # the process starts shedding deliveries before the kernel starts killing
 # it. A push to a busy repository is a dozen deliveries in a second and
 # each one may be 25 MiB, which is the whole reason this plugin is in the
 # composition
 :pressure {:max-rss-bytes 402653184}}
