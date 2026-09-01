(import ../test-support/paths)
(import spork/sh)
(import void/html/assets :as assets)
(import void/html/tailwind :as tw)

# The suite never downloads and never needs a real compiler: everything
# past the platform names is exercised against a shell script that
# behaves the way the standalone binary does — reads --input, writes
# --output, stays alive under --watch. What that leaves untested is the
# bytes GitHub serves, which no test on this machine could assert on
# anyway; what it covers is every decision this module makes about them.

(def tmp "test/tmp-tailwind")
(sh/rm tmp)
(os/mkdir "test")
(os/mkdir tmp)

# -- platform names ------------------------------------------------------

(assert (= "macos-arm64" (tw/platform :macos :aarch64)))
(assert (= "macos-x64" (tw/platform :macos :x64)))
(assert (= "linux-x64" (tw/platform :linux :x64 false)))
(assert (= "linux-arm64-musl" (tw/platform :linux :aarch64 true))
        "alpine gets the musl build")
(assert (= "windows-x64" (tw/platform :mingw :x64)))
(assert (= "macos-arm64" (tw/platform :macos :aarch64 true))
        "musl is a linux question")

(def [ok err] (protect (tw/platform :plan9 :x64)))
(assert (not ok))
(assert (string/find ":bin" err)
        "an unpublished platform names the way out, not just the failure")
(assert (not (first (protect (tw/platform :linux :sparc)))))

(assert (= "tailwindcss-macos-arm64" (tw/asset-name "macos-arm64")))
(assert (= "tailwindcss-windows-x64.exe" (tw/asset-name "windows-x64")))
(assert (= "tailwindcss-linux-x64-4.1.11" (tw/cached-name "linux-x64" "4.1.11")))
(assert (= "tailwindcss-linux-x64-4.1.11" (tw/cached-name "linux-x64" "v4.1.11"))
        "the tag's v never reaches the filename")
(assert (= "tailwindcss-windows-x64-4.1.11.exe" (tw/cached-name "windows-x64" "4.1.11")))

# -- release urls --------------------------------------------------------

(assert (= "https://github.com/tailwindlabs/tailwindcss/releases/latest/download/tailwindcss-macos-arm64"
           (tw/release-url "latest" "macos-arm64")))
(assert (= "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.1.11/tailwindcss-linux-x64"
           (tw/release-url "4.1.11" "linux-x64")))
(assert (= (tw/release-url "4.1.11" "linux-x64") (tw/release-url "v4.1.11" "linux-x64")))

(assert (= "4.1.11"
           (tw/version-in-url
             "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.1.11/tailwindcss-linux-x64")))
(assert (nil? (tw/version-in-url "https://objects.githubusercontent.com/blob?token=x"))
        "the cdn url carries no tag — the redirect before it does")
(assert (nil? (tw/version-in-url nil)))

# -- what counts as configured -------------------------------------------

(assert (tw/configured? {:input "css/app.css" :output "assets/app.css"}))
(assert (not (tw/configured? nil)))
(assert (not (tw/configured? {})))
(assert (not (tw/configured? {:enabled false :input "a" :output "b"})))

(def [ok2 err2] (protect (tw/configured? {:input "css/app.css"})))
(assert (not ok2) "half a compile is an error, not a quiet no")
(assert (string/find ":output" err2))
(def [ok3 err3] (protect (tw/configured? {:output "assets/app.css"})))
(assert (not ok3))
(assert (string/find ":input" err3))
(assert (not (first (protect (tw/configured? {:enabled true}))))
        ":enabled true with nothing to compile is a mistake worth saying")

# -- who watches ---------------------------------------------------------

(assert (tw/watching? {} :dev))
(assert (not (tw/watching? {} :prod)) "production serves what the build wrote")
(assert (not (tw/watching? {} :test)) "a test process spawns no compiler")
(assert (tw/watching? {:watch true} :prod))
(assert (not (tw/watching? {:watch false} :dev)))

# -- a compiler that is not the real one ---------------------------------

(defn- fake-compiler [path body]
  (spit path (string "#!/bin/sh\n" body))
  (os/chmod path 8r755)
  path)

(def copier
  ``A stand-in for the standalone binary: --input to --output, and
  --watch keeps it alive the way the real one does — including the part
  that matters here, which is that end of standard input ends the
  watch. Under an inherited /dev/null this script would exit at once,
  so the watcher test below is also the regression test for the pipe.``
  ```
in=""; out=""; watch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) in="$2"; shift 2;;
    --output) out="$2"; shift 2;;
    --watch) watch=1; shift;;
    *) shift;;
  esac
done
mkdir -p "$(dirname "$out")"
cat "$in" > "$out"
if [ -n "$watch" ]; then while read -r _; do :; done; fi
```)

(def bin-dir (string tmp "/bin"))
(os/mkdir bin-dir)
(def fake (fake-compiler (string bin-dir "/tailwindcss") copier))

# -- finding it ----------------------------------------------------------

(assert (= fake ((tw/locate {:bin fake}) :path)))
(assert (= :config ((tw/locate {:bin fake}) :source)))

(def [ok4 err4] (protect (tw/locate {:bin (string tmp "/nowhere")})))
(assert (not ok4) "a named compiler that is not there is not a fall through")
(assert (string/find ":bin" err4))

(def cache (string tmp "/cache"))
(os/mkdir cache)
(fake-compiler (string cache "/tailwindcss-linux-x64-4.1.9") copier)
(fake-compiler (string cache "/tailwindcss-linux-x64-4.1.11") copier)
(fake-compiler (string cache "/tailwindcss-linux-x64-4.2.0") copier)
(fake-compiler (string cache "/tailwindcss-macos-arm64-9.9.9") copier)

(def found (tw/cached cache "linux-x64"))
(assert (= 3 (length found)) "only this platform's binaries")
(assert (= ["4.2.0" "4.1.11" "4.1.9"] (tuple ;(map |($ :version) found)))
        "newest release first, compared as numbers rather than as text")

(def pinned (tw/locate {:dir cache :version "4.1.9" :platform "linux-x64"}))
(assert (string/has-suffix? "4.1.9" (pinned :path)) "a pinned version is one name")
(assert (= :cache (pinned :source)))
(assert (nil? (tw/locate {:dir cache :version "4.0.0" :platform "linux-x64"}))
        "a pinned version that was never installed is absent, not the newest")

(def latest (tw/locate {:dir cache :version "latest" :platform "linux-x64"}))
(assert (= "4.2.0" (latest :version)) "latest is the newest one installed")

(assert (= fake (tw/on-path "tailwindcss" (string "/nope:" bin-dir))))
(assert (nil? (tw/on-path "tailwindcss" "/nope")))

(def real-path (os/getenv "PATH"))
(os/setenv "PATH" (string (os/cwd) "/" bin-dir))
(def on-path (tw/locate {:dir (string tmp "/empty") :platform "linux-x64"
                         :version "latest"}))
(os/setenv "PATH" real-path)
(assert (= :path (on-path :source))
        "with nothing configured and nothing cached, PATH is the last place")
(assert (string/has-suffix? "/tailwindcss" (on-path :path)))

# -- the error when there is none ----------------------------------------

(def [ok5 err5] (protect (tw/need {:dir (string tmp "/empty")
                                   :platform "plan9-x64"})))
(assert (not ok5))
(each fragment ["void assets install" ":bin" "plan9-x64"]
  (assert (string/find fragment err5)
          (string/format "the not-found error is missing %q: %s" fragment err5)))

# -- the argv ------------------------------------------------------------

(def cfg {:input "css/app.css" :output "assets/app.css" :args ["--cwd" "."]})
(assert (= ["tw" "--input" "css/app.css" "--output" "assets/app.css" "--cwd" "."]
           (tuple ;(map string (tw/command "tw" cfg)))))
(assert (= ["tw" "--input" "css/app.css" "--output" "assets/app.css" "--minify" "--cwd" "."]
           (tuple ;(map string (tw/command "tw" cfg {:minify true})))))
(assert (= ["tw" "--input" "css/app.css" "--output" "assets/app.css" "--watch" "--cwd" "."]
           (tuple ;(map string (tw/command "tw" cfg {:watch true})))))

# -- one compile ---------------------------------------------------------

(def src (string tmp "/src"))
(def root (string tmp "/assets"))
(os/mkdir src)
(os/mkdir root)
(spit (string src "/app.css") "@tailwind base;")
(spit (string root "/logo.svg") "<svg/>")

(def compile-cfg {:bin fake
                  :input (string src "/app.css")
                  :output (string root "/app.css")})
(tw/compile! compile-cfg)
(assert (= "@tailwind base;" (string (slurp (string root "/app.css"))))
        "the compiler wrote into the asset root")

(def failing (fake-compiler (string bin-dir "/broken") "exit 3"))
(def [ok6 err6] (protect (tw/compile! (merge compile-cfg {:bin failing}))))
(assert (not ok6) "a compiler that fails fails the build")
(assert (string/find "exited with 3" err6))

# -- the step, inside the fingerprint walk -------------------------------

(sh/rm (string root "/app.css"))
(def out (string tmp "/public"))
(def manifest (assets/build! {:root root :out out
                              :steps [(tw/step compile-cfg)]}))
(assert (= 2 (length manifest))
        "the compiled stylesheet was there to be walked, because the step ran first")
(def target (manifest "app.css"))
(assert (string/has-prefix? "app-" target))
(assert (= "@tailwind base;" (string (slurp (string out "/" target))))
        "and it is fingerprinted like any other file")
(assert (nil? (tw/step {})) "nothing configured, nothing to run")

# -- the watcher ---------------------------------------------------------

(def watched (string tmp "/watched.css"))
(def inst
  (tw/start {:assets {:tailwind (merge compile-cfg {:output watched})}} :dev))
(assert (nil? (inst :disabled)) "a dev profile with a stylesheet watches it")
(assert (inst :running))
# the stand-in writes once and then idles, exactly as tailwind does
# the file appears before it is written, so an empty read is "not yet"
(var seen nil)
(for _ 0 200
  (when (nil? seen)
    (when (os/stat watched)
      (def content (string (slurp watched)))
      (unless (empty? content) (set seen content)))
    (ev/sleep 0.05)))
(assert (= "@tailwind base;" seen) "the watcher's first pass built the stylesheet")
(ev/sleep 0.3)
(assert (inst :running)
        "the compiler is still watching — its stdin is a pipe this process holds open, not an inherited /dev/null")
(assert (= :up ((tw/health inst) :status)))

(tw/stop inst)
(assert (not (inst :running)) "stop leaves no compiler writing the file")

(assert (= :not-watching
           ((tw/start {:assets {:tailwind compile-cfg}} :prod) :disabled))
        "production runs no compiler")
(assert (= :not-configured ((tw/start {} :dev) :disabled)))

# -- the download this suite will not do ---------------------------------
#
# void/tls is not in this composition, so the one thing asserted here is
# the refusal — and that it names both ways out rather than a stack
# trace from the socket.

(def [ok7 err7] (protect (tw/install! {:platform "linux-x64" :dir cache})))
(assert (not ok7))
(each fragment [":void/tls" ":bin"]
  (assert (string/find fragment err7)
          (string/format "the no-tls error is missing %q: %s" fragment err7)))

(sh/rm tmp)
(print "tailwind-test: ok")
