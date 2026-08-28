(declare-project
  :name "void-bench"
  :description "void bench-suite (ADR-0014): the B* mini-apps, the wrk/wrk2 методика runner, Go/FastAPI calibration baselines and 5% regression thresholds."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet. The mini-apps ask for the same
# set again in apps/prelude.janet: they run as subprocesses and the
# runner never imports them.

(declare-source
  :source ["void"])
