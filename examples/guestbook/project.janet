(declare-project
  :name "guestbook"
  :description "A void application."
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core / void-http / void-html / void-htmx / void-dev must be on
# the module path as well — until the packages are published, jpm
# install them from a void checkout (core/, http/, html/, htmx/, dev/).