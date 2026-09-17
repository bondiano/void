### void/cli/repl — `void repl`: a netrepl client into the running
### process.
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

(defn connect
  {:params [{:unix :string? :host :string? :port :any & r} (or (fn [] :any) :nil)]
   :ret :any
   :throws [:string]}
  ``Connect a repl to the running application:

      void repl                     # unix socket from config, else .void/repl.sock
      void repl --unix PATH
      void repl --host H --port P   # tcp netrepl

  `opts` is what void/core/cli parsed off the flags the command
  declares. `config-thunk` (optional) returns the app's :dev :netrepl
  config slice; it is only consulted when no flag points elsewhere, and
  its failure falls back to the defaults (a project whose bootstrap is
  currently broken must still be reachable over the repl).``
  [opts &opt config-thunk]
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
