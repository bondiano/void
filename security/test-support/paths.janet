# Module path for this package's test suite: its own tree plus the void
# packages its sources and its suite reach, projected from the package
# graph (scripts/packages.janet, ADR-0020). jpm test runs each script
# with cwd = the package directory.
(import ../../scripts/packages :as packages)
(packages/test-paths :void/security)
