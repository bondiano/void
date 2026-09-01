# Module path for this example's suite: the void packages it uses,
# projected from the package graph (scripts/packages.janet, ADR-0020).
# jpm test runs each script with cwd = examples/counter/.
(import ../../../scripts/packages :as packages)
(packages/test-paths :example/counter)
