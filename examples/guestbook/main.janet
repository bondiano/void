### guestbook — entrypoint. Run the app with `void dev` (or
### `janet main.janet`); the void CLI (void routes, void repl, ...)
### reads the app binding below.
(import void)
(import void/http)
(import void/html)
(import void/htmx)
(import void/dev)
(import ./app)

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins [:void/http :void/html :void/htmx :void/dev :guestbook/app]
   :profile (keyword (or (os/getenv "VOID_PROFILE") "dev"))})

(defn main [& args]
  (void/run! app))