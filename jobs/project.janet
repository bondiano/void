(declare-project
  :name "void-jobs"
  :description "void/jobs — background jobs: defjob, retries with backoff, priorities, delayed and unique jobs, flows, rate limiting, a dead letter queue and cron schedules (SPEC §5.12, ADR-0012, ROADMAP 2.4)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# spork, for its cron parser — `defschedule` speaks crontab — and for
# nothing else. The kernel and the in-process backend are plain Janet;
# void/jobs-db imports void/db and void/jobs-redis imports void/redis,
# and both are separate plugins in this package, so an application that
# keeps its queue in one process pays for neither.
#
# void-core (../core) must be on the module path as well, plus ../db
# and ../redis for those two plugins; the test suite wires them up
# itself via test-support/paths.janet.

(declare-source
  :source ["void"])
