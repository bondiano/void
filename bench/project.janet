(declare-project
  :name "void-bench"
  :description "void bench-suite (ADR-0014): the B* mini-apps, the wrk/wrk2 методика runner, Go/FastAPI calibration baselines and 5% regression thresholds."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core), void-http (../http) and void-rest (../rest) must
# be on the module path as well; main.janet and the test suite wire
# them up themselves. The mini-apps reach further — ../html and
# ../db + ../db-postgres + ../fdwait for B2/B3, ../pressure for the
# probe's loop-lag meter and for b1-pressure — and wire that up
# themselves in apps/prelude.janet, because the apps run as
# subprocesses and the runner never imports them.

(declare-source
  :source ["void"])
