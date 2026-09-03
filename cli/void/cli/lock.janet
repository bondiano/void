### void/cli/lock — `void plugins lock` and `void plugins check`
### ("manifests are serializable").
###
### A composition is already a value: `plugin/bootstrap` produces the
### plugin list, every extension point with its contributions **in the
### order they resolved**, and the component graph in start order —
### all of it before anything opens a port. What was missing was
### writing that value down, so that "why is the middleware stack
### different in production" is a diff instead of an investigation.
###
### So: `void plugins lock` writes `void.lock`, `void plugins check`
### bootstraps again and compares. In CI the second one is the whole
### mechanism — it costs a `dry-run` (milliseconds, no sockets, no
### database) and it fails the build on a plugin that appeared, a
### version that moved, a contribution that changed places in a chain
### and a deployment shape that is not what the lock was taken in.
###
### **What a hash can honestly cover.** Contributions hold functions,
### and a function has no stable identity across two processes — its
### address is not the same twice, so hashing it would make every run
### differ from every other. What is hashed is therefore the
### contribution *as data*, with each function collapsed to its name:
### a middleware inserted, removed, renamed or re-phased changes the
### hash, and an edit to a middleware's body does not. That is the
### honest boundary, and the file says so in its own header — the tool
### that catches a changed function body is the one that already
### watches the source, not the one that reads a manifest.
###
### The digest is FNV-1a 64 over a canonical rendering (keys sorted,
### one spelling per value). Not a cryptographic hash and not a
### signature: two environments accidentally agreeing is the failure
### this must not have, and an adversary editing a lock file is
### already inside the repository.

(import void/core/init :as core)
(import void/core/plugin :as plugin)
(import void/core/deploy :as deploy)

(def lock-version
  "Format version of the file. It goes in the file so that a future
  change to what is recorded is a readable error rather than a
  mysterious diff."
  1)

(def default-path
  "Where the lock lives unless `--out`/`--lock` says otherwise."
  "void.lock")

# -- the digest ----------------------------------------------------------

(def- fnv-offset (int/u64 "0xcbf29ce484222325"))
(def- fnv-prime (int/u64 "0x100000001b3"))

(defn fnv1a
  "FNV-1a 64 of a byte sequence, as sixteen hex digits."
  [bytes]
  (var h fnv-offset)
  (each b bytes
    (set h (* (bxor h (int/u64 b)) fnv-prime)))
  (string/format "%016x" h))

(defn- fn-label
  ``The name of a function, or "anonymous". `(string f)` would do it
  for a named function and would print an address for the rest, so the
  address never gets into a digest.``
  [f]
  (def named (when (function? f) (get (disasm f) :name)))
  (cond
    named (string named)
    (cfunction? f) (let [s (string f)]
                     (if (string/find "0x" s) "anonymous" s))
    "anonymous"))

(defn canonical
  ``One spelling per value, so that two processes that resolved the
  same composition write the same bytes: dictionary keys sorted by
  their own rendering, sequences in order, functions collapsed to
  their names, and anything else tagged by type rather than by
  identity.``
  [x]
  (cond
    (or (function? x) (cfunction? x)) (string "#fn(" (fn-label x) ")")
    (or (nil? x) (boolean? x) (number? x) (keyword? x) (symbol? x))
    (string/format "%q" x)
    (or (string? x) (buffer? x)) (string/format "%q" (string x))
    (dictionary? x)
    (let [ks (sorted-by canonical (keys x))]
      (string "{" (string/join (map |(string (canonical $) " " (canonical (get x $))) ks) " ") "}"))
    (indexed? x)
    (string "[" (string/join (map canonical x) " ") "]")
    (string "#" (type x))))

(defn digest
  "The fingerprint of any value: FNV-1a 64 over its canonical
  rendering."
  [x]
  (fnv1a (canonical x)))

# -- the composition, as a value -----------------------------------------

(defn- contribution-name
  "How one contribution is named in the file. Most points give their
  contributions a `:name`; the ones that do not are positional and say
  so."
  [value]
  (cond
    (dictionary? value) (get value :name (get value :key :anonymous))
    :anonymous))

(defn- plugin-entry [boot name]
  (def m (get-in boot [:manifests name]))
  (def contributes
    (tabseq [[p vs] :pairs (get m :contributes {})] p (map contribution-name vs)))
  {:name name
   :version (get m :version)
   :active (truthy? (index-of name (boot :active)))
   :components (tuple ;(map |($ :key) (get m :components [])))
   :contributes (freeze contributes)
   :hash (digest {:version (get m :version)
                  :components (tuple ;(map |($ :key) (get m :components [])))
                  :contributes (get m :contributes {})})})

(defn- point-entry [boot name]
  (def e (get-in boot [:extensions name]))
  (def cs (get e :contributions []))
  {:name name
   :owner (e :owner)
   :cardinality (get-in e [:point :cardinality])
   :contributions (tuple ;(map |[($ :plugin) (contribution-name ($ :value))] cs))
   :hash (digest (map |{:plugin ($ :plugin) :value ($ :value)} cs))})

(defn composition
  ``The composition of a bootstrapped app, as the plain value the lock
  file holds and `check` compares. Everything in it comes off the boot
  — nothing is re-derived, so the file describes what would actually
  have run.``
  [boot]
  (def plugins (map |(plugin-entry boot $) (sorted (boot :plugins))))
  (def points (map |(point-entry boot $) (sorted (keys (boot :extensions)))))
  (def components (tuple ;(get-in boot [:system :order] [])))
  (def body
    {:lock-version lock-version
     :void core/version
     :profile (boot :profile)
     :deploy (freeze (get boot :deploy {}))
     :components components
     :plugins (tuple ;plugins)
     :points (tuple ;points)})
  (freeze (merge (table ;(kvs body)) {:hash (digest body)})))

# -- the file ------------------------------------------------------------

(def- header
  ``# void.lock — the composition this application resolves to, written
# by `void plugins lock`. Commit it, and run `void plugins check` in
# CI: a plugin that appeared, a version that moved, a contribution
# that changed places in a chain or a deployment shape that is not the
# one the lock was taken in then fails the build instead of surprising
# a deploy.
#
# The hashes cover the composition *as data*, with every function
# collapsed to its name (void/cli/lock): a middleware inserted,
# removed, renamed or re-phased changes them; an edit inside a
# middleware's body does not.
#
# Generated file — take a new one with `void plugins lock` rather than
# editing this.
``)

(defn- emit-value [x]
  (string/format "%q" x))

(defn- emit-map [m order indent]
  (def pad (string/repeat " " indent))
  (def lines
    (seq [k :in order :when (not (nil? (get m k)))]
      (string/format "%s %s" (emit-value k) (emit-value (get m k)))))
  (string "{" (string/join lines (string "\n" pad " ")) "}"))

(def- plugin-keys [:name :version :active :hash :components :contributes])
(def- point-keys [:name :owner :cardinality :hash :contributions])

(defn render
  ``The lock file as text. One record per line, keys in a fixed order,
  so that a diff of two of these reads like a diff of two
  compositions rather than of two hash tables.``
  [comp]
  (def out @"")
  # janet drops the newline before a long string's closing delimiter,
  # and a header without one would comment the file out
  (buffer/push-string out header)
  (buffer/push-string out "\n{:lock-version ")
  (buffer/push-string out (emit-value (comp :lock-version)))
  (each [k v] [[:void (comp :void)] [:profile (comp :profile)]
               [:deploy (comp :deploy)] [:hash (comp :hash)]]
    (buffer/push-string out (string "\n " (emit-value k) " " (emit-value v))))
  (buffer/push-string out "\n\n :components\n [")
  (buffer/push-string out (string/join (map emit-value (comp :components)) "\n  "))
  (buffer/push-string out "]\n\n :plugins\n [")
  (buffer/push-string out
                      (string/join (map |(emit-map $ plugin-keys 2) (comp :plugins))
                                   "\n  "))
  (buffer/push-string out "]\n\n :points\n [")
  (buffer/push-string out
                      (string/join (map |(emit-map $ point-keys 2) (comp :points))
                                   "\n  "))
  (buffer/push-string out "]}\n")
  (string out))

(defn read-lock
  "Read a lock file back as data. A file that is not one, or is a
  version this build does not know, is an error naming the fix."
  [path]
  (unless (os/stat path :mode)
    (errorf "no lock file at %q — write one with `void plugins lock`" path))
  (def [ok v] (protect (parse (slurp path))))
  (unless (and ok (dictionary? v))
    (errorf "%s is not a lock file — take a new one with `void plugins lock`" path))
  (def version (get v :lock-version))
  (unless (= lock-version version)
    (errorf "%s is lock-version %q, this void writes %q — take a new one with `void plugins lock`"
            path version lock-version))
  v)

# -- the diff ------------------------------------------------------------

(defn- by-name [entries]
  (tabseq [e :in entries] (e :name) e))

(defn- contribution-line
  "One contribution in a chain: `void/http:void.http/session` — the
  plugin that contributed it and the name the point knows it by."
  [c]
  (string/format "%s:%s" (c 0) (c 1)))

(defn- chain [cs]
  (if (empty? cs) "(none)" (string/join (map contribution-line cs) " -> ")))

(defn diff
  ``What changed between a locked composition and the current one, as
  a list of lines. Empty means they are the same composition.

  The order is the order a reader wants to fix things in: the shape of
  the deployment first (it decides what the rest even means), then
  plugins, then the chains inside the points, then the component
  order.``
  [locked current]
  (def out @[])
  (unless (= (locked :profile) (current :profile))
    (array/push out
                (string/format "profile   locked %q, current %q — a lock is per profile (--profile, or a second --lock file)"
                               (locked :profile) (current :profile))))
  (unless (= (get-in locked [:deploy :shape]) (get-in current [:deploy :shape]))
    (array/push out
                (string/format "deploy    [:deploy :shape] locked %q, current %q (%s)"
                               (get-in locked [:deploy :shape])
                               (get-in current [:deploy :shape])
                               (get-in current [:deploy :reason] "resolved"))))
  (unless (= (locked :void) (current :void))
    (array/push out
                (string/format "void      locked %s, current %s"
                               (locked :void) (current :void))))

  (def lp (by-name (locked :plugins)))
  (def cp (by-name (current :plugins)))
  (each name (sorted (keys lp))
    (unless (in cp name)
      (array/push out (string/format "plugin    %q is gone" name))))
  (each name (sorted (keys cp))
    (def c (cp name))
    (if-let [l (get lp name)]
      (do
        (unless (= (l :version) (c :version))
          (array/push out
                      (string/format "plugin    %q %s -> %s" name (l :version) (c :version))))
        (unless (= (l :active) (c :active))
          (array/push out
                      (string/format "plugin    %q is now %s"
                                     name (if (c :active) "active" "deactivated by its :when"))))
        (when (and (= (l :version) (c :version)) (not= (l :hash) (c :hash)))
          (array/push out
                      (string/format "plugin    %q declares something different at the same version %s"
                                     name (c :version)))))
      (array/push out (string/format "plugin    %q is new" name))))

  (def lpt (by-name (locked :points)))
  (def cpt (by-name (current :points)))
  (each name (sorted (keys lpt))
    (unless (in cpt name)
      (array/push out (string/format "point     %q is gone" name))))
  (each name (sorted (keys cpt))
    (def c (cpt name))
    (if-let [l (get lpt name)]
      (unless (= (l :hash) (c :hash))
        (array/push out (string/format "point     %q" name))
        (array/push out (string/format "            was  %s" (chain (l :contributions))))
        (array/push out (string/format "            now  %s" (chain (c :contributions)))))
      (array/push out (string/format "point     %q is new" name))))

  (unless (deep= (locked :components) (current :components))
    (array/push out "components  the start order changed")
    (array/push out (string/format "            was  %s"
                                   (string/join (map |(string/format "%q" $) (locked :components)) " ")))
    (array/push out (string/format "            now  %s"
                                   (string/join (map |(string/format "%q" $) (current :components)) " "))))
  out)

# -- the commands --------------------------------------------------------

(defn- parse-flags [args]
  (def opts @{})
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (case a
      "--out" (do (put opts :path (args (inc i))) (+= i 2))
      "--lock" (do (put opts :path (args (inc i))) (+= i 2))
      (errorf "void plugins: unknown flag %q" a)))
  opts)

(defn write-lock
  ``The body of `void plugins lock`: write the current composition to
  `void.lock` (or `--out PATH`). Returns the composition.``
  [boot & args]
  (def opts (parse-flags args))
  (def path (get opts :path default-path))
  (def comp (composition boot))
  (spit path (render comp))
  (printf "  wrote %s" path)
  (printf "  %d plugins, %d extension points, %d components — %s"
          (length (comp :plugins)) (length (comp :points))
          (length (comp :components)) (comp :hash))
  comp)

(defn check-lock
  ``The body of `void plugins check`: compare the lock file against the
  composition this checkout resolves to now. Prints nothing but the
  verdict when they agree; prints the differences and returns false
  when they do not — the caller turns that into exit 1.``
  [boot & args]
  (def opts (parse-flags args))
  (def path (get opts :path default-path))
  (def locked (read-lock path))
  (def current (composition boot))
  (if (= (locked :hash) (current :hash))
    (do (printf "  %s matches — %d plugins, %s"
                path (length (current :plugins)) (current :hash))
        true)
    (do
      (printf "  %s does not match this composition" path)
      (print)
      (each l (diff locked current) (print "  " l))
      (print)
      (print "  `void plugins lock` takes a new one if the change is intended.")
      false)))

(defn show
  ``The body of `void plugins`: the composition as the lock file sees
  it, without writing anything. The same value, so what it prints is
  what a lock would record.``
  [boot & args]
  (unless (empty? args)
    (errorf "void plugins takes no arguments (got %q) — did you mean `void plugins lock`?"
            (string/join args " ")))
  (def comp (composition boot))
  (printf "profile %q  shape %q  void %s"
          (comp :profile) (get-in comp [:deploy :shape]) (comp :void))
  (printf "hash    %s" (comp :hash))
  (print)
  (print "plugins")
  (each p (comp :plugins)
    (printf "  %-24s %-8s %-10s %s"
            (string/format "%q" (p :name))
            (or (p :version) "-")
            (if (p :active) "active" "inactive")
            (p :hash)))
  (print)
  (print "extension points")
  (each pt (comp :points)
    (unless (empty? (pt :contributions))
      (printf "  %-30s %s"
              (string/format "%q" (pt :name))
              (chain (pt :contributions)))))
  comp)

(def commands
  "The `void plugins ...` subcommands, as data — the dispatcher below
  is a lookup, not a case. `void plugins` with no subcommand prints."
  {"lock" write-lock "check" check-lock})

(defn dispatch
  ``Run `void plugins [lock|check] [flags]` against a bootstrapped app.
  Returns whatever the subcommand returns; `check` returns false when
  the lock does not match, which is the caller's exit code.``
  [boot args]
  (def sub (first args))
  (if (nil? sub)
    (show boot)
    (let [f (or (in commands sub)
                (errorf "void plugins: unknown subcommand %q (one of: lock, check)" sub))]
      (f boot ;(drop 1 args)))))
