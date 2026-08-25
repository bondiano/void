### void/core/system — component system (SPEC.md §3.1).
### System = map of components; component = data with start/stop/health.
### Registry -> validation (cycles, missing deps, duplicates) -> topological
### sort -> start in dependency order, stop in reverse.
