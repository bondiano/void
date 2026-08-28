# blog — the config layer every profile shares (void/core/config:
# plugin defaults <- default.janet <- <profile>.janet <- VOID_* env
# vars <- CLI overrides; `void config explain :cache :ttl` shows where
# a value came from).

{# Three components provide :void/jobs-backend once void/jobs-db is in
 # the composition, and the kernel refuses to guess: the queue lives in
 # the database, next to the data it is bookkeeping for.
 :void/jobs-backend {:impl :jobs/db}

 :db {:migrations {:dir "db/migrations"}}

 # the article list is cached for a minute and dropped on every write —
 # the recount job invalidates it too, because it is what makes the
 # counter change
 :cache {:prefix "blog:" :ttl 60}

 :jobs {:queues {:maintenance {:concurrency 2}}}}
