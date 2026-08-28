# blog :test profile — the suite overrides the sqlite path with a
# temporary file (and the Postgres connection with VOID_TEST_PG), so
# what is left here is the part that is the same either way: no worker
# and no scheduler, because a test drives the queue itself with
# (jobs/drain!).

{:jobs {:worker {:enabled false} :scheduler {:enabled false}}
 :cache {:ttl 60}}
