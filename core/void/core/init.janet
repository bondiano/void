### void/core — the only mandatory dependency of a void application. Does
### not pull in HTTP, DB, or anything else.

(def version
  ``The bundle version — the one place it is written. project.janet
  projects it into jpm's `:version`, `void new` pins the generated
  project's dependency to its tag, `void version` prints it, and
  scripts/gen-changelog.janet checks the newest release tag against it.``
  "0.5.0")

(def release-tag
  ``The git tag this version releases as — vMAJOR.MINOR, the way the
  repository has named every release (v0.1 .. v0.5); a patch release
  would be vMAJOR.MINOR.PATCH. The tag is not written anywhere by hand:
  it is what `version` says.``
  (let [[major minor patch] (string/split "." version)]
    (if (= patch "0")
      (string "v" major "." minor)
      (string "v" version))))

(def void-api
  "Plugin protocol version; manifests declare `:void-api` and the host
  rejects plugins with an incompatible major version."
  1)
