### hub — entrypoint. Run the app with `void dev` (or
### `janet main.janet`); the void CLI (void routes, void repl, ...)
### reads the app binding below.
(import void/cli :as cli)
(import void/http)
(import void/html)
(import void/htmx)
(import void/dev)
(import ./app)

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins [:void/http :void/html :void/htmx :void/dev :hub/app]})

# void/dev is a dev-time plugin: it serves a repl and watches the tree,
# and it builds that repl's environment with `require` — which a single
# binary has no source tree to require from (docs/DEPLOY.md). So the
# production composition is this one without it, and dropping a plugin
# from a list is the whole of the change.
(defn plugins
  "The composition for a profile."
  [profile]
  (if (= :prod profile)
    (filter |(not= :void/dev $) (app :plugins))
    (app :plugins)))

(defn main [& args]
  # The profile is read here rather than in `app` above: `jpm build`
  # marshals this file's values into the executable, so anything a
  # value computes is computed once, on the machine that built it.
  (def profile (keyword (or (os/getenv "VOID_PROFILE") "dev")))
  # cli/app-main runs the app when there are no arguments and is the
  # `void` binary when there are — so `./build/hub db migrate`
  # works on a target with no janet and no source tree, against exactly
  # the composition inside this executable (docs/DEPLOY.md).
  (cli/app-main {:plugins (plugins profile) :profile profile} ;(drop 1 args)))
