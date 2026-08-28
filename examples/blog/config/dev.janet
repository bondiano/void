# blog :dev profile.

{:http {:port 8080}

 # a file next to the checkout; `VOID_BLOG_DB=postgres void dev` picks
 # the other driver and reads [:db-postgres] instead
 :db-sqlite {:path "db/blog.sqlite3"}
 :db-postgres {:database "blog_dev"}

 # one process here does everything — enqueueing, running and
 # scheduling. In production those are usually three deployments, which
 # is why both switches are off by default.
 :jobs {:worker {:enabled true :queues [:default :maintenance]}
        :scheduler {:enabled true}}}
