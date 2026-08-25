### void/core — the only mandatory dependency of a void application.
### Does not pull in HTTP, DB, or anything else (SPEC.md §3).

(def version "0.0.1")

(def void-api
  "Plugin protocol version; manifests declare `:void-api` and the host
  rejects plugins with an incompatible major version (SPEC.md part II, 1.5)."
  1)
