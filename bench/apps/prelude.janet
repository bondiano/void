### Module-path setup for the bench mini-apps: the void packages they
### reach, projected from the package graph (scripts/packages.janet,
### ADR-0020) — B1's rest, B3's html, B2/B3's db + db-postgres over the
### native void/fdwait, and pressure for the probe's loop-lag meter.
###
### The apps run as subprocesses the runner spawns from the bench root,
### and a human may run one from anywhere, so the paths are derived from
### file locations rather than from the working directory.

(import ../../scripts/packages :as packages)

(packages/test-paths :void/bench)
