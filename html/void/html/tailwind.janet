### void/html/tailwind — the standalone compiler, without node.
###
### Tailwind publishes its compiler as one static binary per platform,
### and that binary is the whole toolchain: no npm, no node_modules,
### nothing on the user's PATH that void did not put there. So this
### module is three small things and no build system — *where the
### binary is* (`locate`), *how it gets there* (`install!`) and *how it
### is run* (`compile!`, the watcher component) — and the asset
### pipeline stays what it already was: the compiler writes a
### stylesheet into the asset root, and `assets/build!` fingerprints it
### with everything else (its `:steps`).
###
### **Detection before download.** A project that vendored the binary,
### a distribution that packages it, a CI image that cached it — none
### of them may reach for the network. `locate` answers in three
### places, in order: the configured `:bin`, this project's cache
### directory, then PATH. Only `void assets install` downloads, and
### only when it is asked to.
###
### **A missing compiler is a sentence, not a silence.** Everything
### that needs it and cannot find it errors with the platform it looked
### for, the places it looked, and the command that fixes it — and a
### half-named `[:html :assets :tailwind]` (an `:input` with no
### `:output`) is refused at boot rather than at the first build. The
### one outcome ruled out is a build that quietly ships yesterday's CSS.
###
### **https belongs to the composition.** The download is a
### `http/client` request like any other, so it needs `:void/tls`
### composed (ADR-0038). Without it the error names both ways out —
### compose the plugin, or put the binary where `locate` looks —
### because "this process can speak TLS" is a fact about the
### composition and not something to work around here.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/http/client :as client)

(def repo
  "Where the standalone binaries are published."
  "tailwindlabs/tailwindcss")

(def defaults
  ``What `[:html :assets :tailwind]` means when it does not say:

    :version    which release to install ("latest" resolves through
                GitHub's redirect and is cached under the tag it lands
                on, so the name on disk is never "latest")
    :dir        the cache directory — hidden, so void/dev's watcher
                walks past it (it skips dotted directories)
    :timeout    seconds for the whole download; a compiler is ~100 MB
    :max-bytes  what the download is allowed to be — a client without
                a limit is a memory bug waiting for a bad URL``
  {:version "latest"
   :dir ".void/bin"
   :timeout 300
   :max-bytes (* 256 1024 1024)})

# -- the platform --------------------------------------------------------
#
# Two tables and no cleverness: the names below are the ones in the
# release assets. An unknown platform is an error rather than a guessed
# filename, and `:platform` in the config overrides the whole answer —
# so a machine this module has never heard of is a one-line config
# entry, not a patch.

(def os-names
  "os/which -> what tailwind calls that platform in a release asset."
  {:macos "macos" :linux "linux" :windows "windows"
   :mingw "windows" :cygwin "windows"})

(def arch-names
  "os/arch -> what tailwind calls that architecture."
  {:x64 "x64" :x86-64 "x64" :aarch64 "arm64" :arm64 "arm64"})

(defn musl?
  ``Is this machine's libc musl? Alpine is the distribution that makes
  the difference matter and the file below is how it says so; anything
  else answers false and gets the glibc binary, which is the right
  guess everywhere the question is not being asked.``
  []
  (truthy? (os/stat "/etc/alpine-release")))

(defn platform
  ``The `<os>-<arch>` this machine is in tailwind's release assets —
  "macos-arm64", "linux-x64-musl". Arguments are for tests and for the
  config's `:platform` override; left out they are read from the
  process.``
  [&opt which arch musl]
  (default which (os/which))
  (default arch (os/arch))
  (def o (or (get os-names which)
             (errorf "tailwind: no standalone compiler is published for %q — set [:html :assets :tailwind :bin] to one this machine can run"
                     which)))
  (default musl (and (= "linux" o) (musl?)))
  (def a (or (get arch-names arch)
             (errorf "tailwind: no standalone compiler is published for %q on %q — set [:html :assets :tailwind :bin] to one this machine can run"
                     arch which)))
  (string o "-" a (if (and musl (= "linux" o)) "-musl" "")))

(defn windows?
  "Does this platform name a Windows machine? (Only its binaries carry
  an extension.)"
  [plat]
  (string/has-prefix? "windows-" plat))

(defn asset-name
  "The release asset for a platform: tailwindcss-<platform>[.exe]."
  [plat]
  (string "tailwindcss-" plat (if (windows? plat) ".exe" "")))

(defn version-string
  "A release as this module writes it: without the tag's leading v."
  [version]
  (def v (string version))
  (if (string/has-prefix? "v" v) (string/slice v 1) v))

(defn cached-name
  ``What a downloaded compiler is called in the cache directory. The
  version is in the name, so moving a project to a new release gets it
  a new file instead of a stale binary at the right path.``
  [plat version]
  (string "tailwindcss-" plat "-" (version-string version)
          (if (windows? plat) ".exe" "")))

(defn release-url
  "Where a release's asset is downloaded from. \"latest\" goes through
  GitHub's own redirect rather than through an API call."
  [version plat]
  (def asset (asset-name plat))
  (if (= "latest" (string version))
    (string "https://github.com/" repo "/releases/latest/download/" asset)
    (string "https://github.com/" repo "/releases/download/v"
            (version-string version) "/" asset)))

(def- tag-peg
  (peg/compile '(* (thru "/releases/download/v") (<- (some (if-not "/" 1))) "/")))

(defn version-in-url
  ``The release a download URL names — ".../releases/download/v4.1.11/
  tailwindcss-macos-arm64" -> "4.1.11" — or nil for a URL that carries
  no tag (the CDN URL the last redirect lands on is one).``
  [url]
  (when (string? url)
    (when-let [m (peg/match tag-peg url)]
      (first m))))

# -- the configuration ---------------------------------------------------

(defn setting
  "One `[:html :assets :tailwind]` value, with this module's default
  behind it."
  [cfg key]
  (get (or cfg {}) key (get defaults key)))

(defn configured?
  ``Does this composition compile a stylesheet? Yes when the slice
  names both ends of the compile — `:input` (the source, which names
  its own template sources) and `:output` (where the compiled CSS
  lands, inside `[:html :assets :root]` so that dev serves it and
  `assets/build!` fingerprints it).

  Naming one end and not the other is an error rather than a `false`:
  a stylesheet that is configured almost enough to build is the exact
  case where silence costs an afternoon.``
  [cfg]
  (def cfg (or cfg {}))
  (def input (cfg :input))
  (def output (cfg :output))
  (cond
    (= false (cfg :enabled)) false
    (and input output) true
    (true? (cfg :enabled))
    (error "[:html :assets :tailwind] :enabled is true but no stylesheet is named — set :input (the source css) and :output (the compiled css, inside [:html :assets :root])")
    (or input output)
    (errorf "[:html :assets :tailwind] names %s and not %s — a compile needs both ends"
            (if input ":input" ":output")
            (if input ":output" ":input"))
    false))

(defn watching?
  ``Should this process run the compiler in `--watch`? `:watch` says so
  outright; left out, the profile answers, and only `:dev` says yes —
  a dev process recompiles as you type, a production one serves what
  `void assets build` already wrote, and a test process has no business
  spawning a compiler at all.``
  [cfg profile]
  (def w (get (or cfg {}) :watch))
  (if (nil? w) (= :dev profile) (truthy? w)))

# -- finding the compiler ------------------------------------------------

(defn- executable? [path]
  (def st (os/stat path))
  (and st
       (= :file (st :mode))
       (string/find "x" (st :permissions))
       true))

(defn on-path
  ``The first executable called `name` on PATH, or nil. Resolved here
  rather than by a shell: asking `sh` where a binary is means a
  subprocess and a quoting question, and PATH is a string with
  separators in it.``
  [name &opt path-value windows]
  (default path-value (os/getenv "PATH"))
  (default windows (get os-names (os/which)))
  (when path-value
    (def sep (if (= "windows" windows) ";" ":"))
    (var found nil)
    (each dir (string/split sep path-value)
      (when (and (nil? found) (not (empty? dir)))
        (def candidate (string dir "/" name))
        (when (executable? candidate)
          (set found candidate))))
    found))

(defn- version-key [v]
  (map |(or (scan-number $) 0) (string/split "." v)))

(defn- newer? [a b]
  (def ka (version-key a))
  (def kb (version-key b))
  (var out nil)
  (for i 0 (max (length ka) (length kb))
    (when (nil? out)
      (def x (get ka i 0))
      (def y (get kb i 0))
      (unless (= x y) (set out (> x y)))))
  (if (nil? out) false out))

(defn cached
  ``The compilers already in the cache directory for this platform,
  newest release first: [{:path :version} ...].

  With `:version` pinned this is one name or none. With "latest" it is
  whatever `void assets install` has put there — the cache *is* the
  record of what was installed, so answering "which one" never goes to
  the network.``
  [dir plat]
  (def prefix (string "tailwindcss-" plat "-"))
  (def suffix (if (windows? plat) ".exe" ""))
  (def out @[])
  (when (= :directory (get (os/stat (or dir "")) :mode))
    (each name (os/dir dir)
      (when (and (string/has-prefix? prefix name)
                 (string/has-suffix? suffix name))
        (def v (string/slice name (length prefix)
                             (if (empty? suffix) -1 (- -1 (length suffix)))))
        (unless (empty? v)
          (def path (string dir "/" name))
          (when (executable? path)
            (array/push out {:path path :version v}))))))
  (sort out (fn [a b] (newer? (a :version) (b :version))))
  out)

(defn places
  ``The three places a compiler is looked for, in order, as text — what
  an error message and `void assets info` both need to say.``
  [cfg &opt plat]
  (default plat (or (get (or cfg {}) :platform) (platform)))
  (def dir (setting cfg :dir))
  (def version (setting cfg :version))
  [(if-let [b (get (or cfg {}) :bin)]
     (string "[:html :assets :tailwind :bin] " b)
     "[:html :assets :tailwind :bin] (not set)")
   (string dir "/" (if (= "latest" (string version))
                     (string "tailwindcss-" plat "-*")
                     (cached-name plat version)))
   (string "PATH (" (asset-name plat) " or tailwindcss)")])

(defn locate
  ``Where this composition's compiler is: {:path :source :version} or
  nil. `:source` is `:config` (the configured `:bin`), `:cache` (this
  project's download) or `:path`.

  A configured `:bin` that is not there is an error rather than a fall
  through to the next place: a project that named its compiler is not
  asking for a different one.``
  [cfg]
  (def cfg (or cfg {}))
  (def plat (or (cfg :platform) (platform)))
  (def version (string (setting cfg :version)))
  (if-let [bin (cfg :bin)]
    (if (executable? bin)
      {:path bin :source :config}
      (errorf "[:html :assets :tailwind :bin] is %q, which is not an executable file" bin))
    (or (if (= "latest" version)
          (when-let [c (first (cached (setting cfg :dir) plat))]
            (merge c {:source :cache}))
          (let [path (string (setting cfg :dir) "/" (cached-name plat version))]
            (when (executable? path)
              {:path path :version version :source :cache})))
        (when-let [p (or (on-path (asset-name plat)) (on-path "tailwindcss"))]
          {:path p :source :path}))))

(defn need
  "The compiler, or an error naming every place that was looked in and
  the command that would end the search."
  [cfg]
  (def plat (or (get (or cfg {}) :platform) (platform)))
  (or (locate cfg)
      (errorf "tailwind: no standalone compiler for %s. Looked in: %s. Run `void assets install` to download one, or set [:html :assets :tailwind :bin] to a compiler you already have"
              plat (string/join (places cfg plat) "; "))))

# -- installing it -------------------------------------------------------

(defn- ensure-dir [dir]
  (var acc "")
  (each part (string/split "/" dir)
    (set acc (if (empty? acc) part (string acc "/" part)))
    (unless (or (empty? acc) (= "." acc))
      (os/mkdir acc)))
  (unless (= :directory (get (os/stat dir) :mode))
    (errorf "tailwind: cannot create the cache directory %q" dir))
  dir)

(def- no-tls
  (string "an https download needs TLS, and this composition has none: "
          "add :void/tls to :plugins (ADR-0038), or download the "
          "compiler yourself and point [:html :assets :tailwind :bin] at it"))

(defn- urls-of [resp]
  (array ;(get resp :redirects []) (get resp :url "")))

(defn resolve-release
  ``Which release "latest" is: a HEAD that follows GitHub's redirect and
  reads the tag out of a URL on the way. Returns the version, or nil
  when no URL in the chain carried one — then the download itself is
  what names it.``
  [version plat &opt timeout]
  (if (not= "latest" (string version))
    (version-string version)
    (let [[ok resp] (protect (client/head (release-url "latest" plat)
                                          {:follow 5
                                           :timeout (or timeout (defaults :timeout))}))]
      (when ok
        (var found nil)
        (each u (urls-of resp)
          (when (nil? found) (set found (version-in-url u))))
        found))))

(defn install!
  ``Download the standalone compiler into the cache directory and make
  it executable. Returns {:path :version :bytes :url :cached}.

  A release already in the cache is left alone (`:cached` true) unless
  `opts` says `:force` — the point of naming the version in the file is
  that a second install is a no-op.

  The write is a rename: the compiler appears under its final name
  whole or not at all, which is what keeps a cancelled download from
  looking like an installed one.``
  [cfg &opt opts]
  (default opts {})
  (def cfg (or cfg {}))
  (def plat (or (cfg :platform) (platform)))
  (def dir (setting cfg :dir))
  (def timeout (setting cfg :timeout))
  (def asked (string (setting cfg :version)))
  (unless (client/tls-available?)
    (errorf "tailwind: cannot download %s — %s" (asset-name plat) no-tls))
  (def resolved (resolve-release asked plat timeout))
  (when (and resolved (not (opts :force)))
    (def path (string dir "/" (cached-name plat resolved)))
    (when (executable? path)
      (break {:path path :version resolved :cached true
              :url (release-url resolved plat)})))
  (def url (release-url asked plat))
  (def resp (client/request {:url url
                             :follow 5
                             :timeout timeout
                             :max-body (setting cfg :max-bytes)}))
  (unless (= 200 (resp :status))
    (errorf "tailwind: %s answered %d %s — is %q a published release?"
            url (resp :status) (get resp :message "") asked))
  (def body (or (resp :body) ""))
  (when (empty? body)
    (errorf "tailwind: %s answered with an empty body" url))
  # the tag comes from the redirect chain when the config did not name
  # one: "latest" is a URL, and the file on disk gets a real version
  (var version resolved)
  (each u (urls-of resp)
    (when (nil? version) (set version (version-in-url u))))
  (when (nil? version) (set version (version-string asked)))
  (ensure-dir dir)
  (def path (string dir "/" (cached-name plat version)))
  (def tmp (string path ".tmp."
                   (string/join (seq [x :in (os/cryptorand 4)]
                                     (string/format "%02x" x)))))
  (spit tmp body)
  (os/chmod tmp 8r755)
  (os/rename tmp path)
  {:path path :version version :bytes (length body) :url url :cached false})

# -- running it ----------------------------------------------------------

(defn command
  ``The argv for one compile: the binary, the two ends of the compile,
  and whatever the project added in `:args` (a `-c` for a tailwind 3
  config, a `--cwd`). `:minify` and `:watch` come from `opts` rather
  than from the config, because a build minifies and a watcher does
  not, and both read the same slice.``
  [bin cfg &opt opts]
  (default opts {})
  (def cfg (or cfg {}))
  (def argv @[bin
              "--input" (cfg :input)
              "--output" (cfg :output)])
  (when (opts :minify) (array/push argv "--minify"))
  (when (opts :watch) (array/push argv "--watch"))
  (each a (get cfg :args []) (array/push argv a))
  argv)

(defn- describe-exit [code argv]
  (string/format "tailwind: %s exited with %d" (string/join argv " ") code))

(defn compile!
  ``Compile the stylesheet once, and error when the compiler does. The
  compiler's own output goes to this process's stdout and stderr —
  tailwind explains a bad `@apply` better than any wrapper would.

  This is the `:steps` thunk `assets/build!` runs before it walks the
  asset root, which is the whole of the ordering: the compiled CSS is
  in `:root` by the time anything is fingerprinted.``
  [cfg &opt opts]
  (default opts {})
  (def bin ((need cfg) :path))
  (def argv (command bin cfg (merge {:minify (get cfg :minify true)} opts)))
  (def code (os/proc-wait (os/spawn argv :p)))
  (unless (zero? code) (error (describe-exit code argv)))
  {:bin bin :output (cfg :output) :argv (tuple ;argv)})

(defn step
  "The `assets/build!` step for a composition, or nil when it compiles
  no stylesheet."
  [cfg &opt opts]
  (when (configured? cfg)
    (fn tailwind-step [] (compile! cfg opts))))

# -- the watcher ---------------------------------------------------------
#
# `tailwind --watch` is a process, not a loop we could run: it holds
# its own scan of the template sources between rebuilds, which is the
# entire reason it is faster than re-running the compiler. So the
# component is the child process and its two ends — one spawn, one
# signal — and void/dev's own watcher never learns that it exists: the
# compiled CSS is not a .janet file, and the cache directory is hidden,
# so neither the output nor the compiler shows up in a reload.
#
# **The child gets a pipe for stdin, and the point is that it stays
# open.** A watching tailwind exits when its standard input reaches
# end of file — that is how the tool is told to stop when nobody can
# signal it — so a `void dev` started from anything but a terminal
# (a supervisor, `&`, a container) would hand it `/dev/null` and watch
# it quit on the first read. A pipe this process holds never does that,
# and closing it in `stop` is then the polite way to ask, with the
# signal as the backstop. Nothing here depends on a flag, so a
# `:bin` pointed at some other compiler behaves the same.
#
# A compiler that exits on its own is the case worth designing for. It
# means a config error the developer is looking at right now, and the
# dev process should say so on the line after tailwind's own message
# rather than quietly stop rebuilding.

(defn start
  ``Start the compiler in `--watch` from the `:html` config slice.
  Returns the instance table, or {:disabled ...} when this composition
  compiles nothing or this profile does not watch.``
  [cfg &opt profile]
  (default profile :dev)
  (def tw (get-in (or cfg {}) [:assets :tailwind] {}))
  (cond
    (not (configured? tw)) {:disabled :not-configured}
    (not (watching? tw profile)) {:disabled :not-watching}
    (do
      (def bin ((need tw) :path))
      (def argv (command bin tw {:watch true :minify false}))
      (def proc (os/spawn argv :p {:in :pipe}))
      (def inst @{:bin bin :proc proc :argv (tuple ;argv)
                  :output (tw :output) :running true
                  :exited (ev/chan 1)})
      (ev/go (fn tailwind-reaper []
               (def code (os/proc-wait proc))
               (ev/give (inst :exited) code)
               (when (inst :running)
                 (put inst :running false)
                 (eprint (describe-exit code argv))
                 (eprint "void/html: the stylesheet is no longer being rebuilt"))))
      inst)))

(defn stop
  "Signal the compiler and wait for it to go, so a restarted dev
  process does not leave a second one writing the same file."
  [inst]
  (when (and (inst :proc) (inst :running))
    (put inst :running false)
    # end of input is how a watching compiler is asked to stop; the
    # signal below is what happens when it does not
    (protect (:close (get-in inst [:proc :in])))
    (protect (os/proc-kill (inst :proc) false :term))
    (def [gone _] (protect (ev/with-deadline 5 (ev/take (inst :exited)))))
    (unless gone (protect (os/proc-kill (inst :proc))))
    nil))

(defn health
  "What the watcher reports: :up while the compiler is running, :down
  once it has exited on its own."
  [inst]
  (cond
    (inst :disabled) {:status :up :watching false :why (inst :disabled)}
    (inst :running) {:status :up :watching true :output (inst :output)}
    {:status :down :watching false
     :message "the tailwind compiler exited — the stylesheet is stale"}))

(def component
  "The :html/tailwind system component — the compiler in --watch, for
  as long as the process it belongs to."
  (system/component :html/tailwind
    :doc "The standalone tailwind compiler in --watch: a dev process rebuilds the stylesheet as you type, a :prod one serves what `void assets build` wrote."
    :config {:key :html}
    :start (fn [_ cfg] (start (or cfg {}) (get plugin/current-boot :profile :dev)))
    :stop stop
    :health health))
