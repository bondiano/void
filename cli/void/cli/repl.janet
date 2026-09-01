### void/cli/repl — `void repl`: a netrepl client into the running
### process (SPEC.md §5.17).
###
### The void/dev plugin serves netrepl on a unix socket
### (.void/repl.sock) by default; this connects spork's stock client to
### it. The app config is consulted best-effort — a project whose
### bootstrap currently fails must still be reachable over the repl —
### and explicit flags win over everything.

(import spork/netrepl)

(def default-unix-path
  "Where void/dev serves netrepl unless configured otherwise."
  ".void/repl.sock")

(defn- parse-flags [args]
  (def opts @{})
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (case a
      "--unix" (do (put opts :unix (args (inc i))) (+= i 2))
      "--host" (do (put opts :host (args (inc i))) (+= i 2))
      "--port" (do (put opts :port (args (inc i))) (+= i 2))
      "--help" (do (put opts :help true) (++ i))
      (errorf "void repl: unknown flag %q (try --help)" a)))
  opts)

(defn connect
  ``Connect a repl to the running application:

      void repl                     # unix socket from config, else .void/repl.sock
      void repl --unix PATH
      void repl --host H --port P   # tcp netrepl

  `config-thunk` (optional) returns the app's :dev :netrepl config
  slice; it is only consulted when no flag points elsewhere, and its
  failure falls back to the defaults (a project whose bootstrap is
  currently broken must still be reachable over the repl).``
  [args &opt config-thunk]
  (def opts (parse-flags args))
  (when (opts :help)
    (print "usage: void repl [--unix PATH | --host HOST --port PORT]")
    (break))
  (def cfg
    (if (or (opts :unix) (opts :host) (nil? config-thunk))
      {}
      (let [[ok c] (protect (config-thunk))]
        (if (and ok (dictionary? c)) c {}))))
  (def [host port]
    (cond
      (opts :host) [(opts :host) (string (or (opts :port) 9365))]
      (opts :unix) [:unix (opts :unix)]
      (get cfg :host) [(cfg :host) (string (get cfg :port 9365))]
      [:unix (or (opts :unix) (get cfg :unix) default-unix-path)]))
  (when (and (= :unix host) (not (os/stat port)))
    (errorf "no netrepl socket at %q — is the app running? (janet main.janet)" port))
  (netrepl/client host port (string "void-repl:" (os/cwd))))
