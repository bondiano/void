(declare-project
  :name "void-bench"
  :description "void bench-suite (ADR-0014): the B* mini-apps, the wrk/wrk2 методика runner, Go/FastAPI calibration baselines and 5% regression thresholds."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core), void-http (../http) and void-rest (../rest) must
# be on the module path as well; main.janet and the test suite wire
# them up themselves.

(declare-source
  :source ["void"])
