(declare-project
  :name "void-i18n"
  :description "void/i18n — a dictionary is a contribution merged in resolution order, the request's locale is a dyn, and the schema errors of forms, admin and problem+json translate through the seam the core has carried since wave 0."
  :version "0.0.1")

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see test-support/paths.janet.

(declare-source
  :source ["void"])
