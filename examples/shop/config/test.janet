# shop :test profile — the suite overrides the sqlite path with a
# temporary file (and the Postgres connection with VOID_TEST_PG), so
# what is left here is the part that is the same either way: no worker
# and no scheduler, because a test drives the queue itself with
# (jobs/drain!).

{:jobs {:worker {:enabled false} :scheduler {:enabled false}}
 # the sampler stays composed (the health tile, the dashboard) but never
 # sheds: a suite on a busy runner would otherwise read its own 503s as
 # failures — the history tab of a row was one such
 :pressure {:enabled false}
 :cache {:ttl 60}
 # the gateway in shop/payments is a stand-in for a network call, and a
 # test that flipped a coin would be a test that fails one run in five
 :shop {:payments {:failure-rate 0}}}
