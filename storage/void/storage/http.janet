### void/storage-http — serving the local store's files (ADR-0039 §4).
###
### The piece of void/storage that needs void/http, kept a separate
### plugin so a worker or a CLI process stores files without dragging
### the HTTP kernel in — the void/cache — void/cache-http split. One
### route: GET `[:storage :serve :prefix]`/*key, answered through the
### existing static machinery (`static/file-response`), so an upload
### gets the same strong ETag, If-None-Match and Range handling the
### stylesheet gets, out of the one implementation of them.
###
### `[:storage :serve :signed] true` turns the prefix private: every
### request must carry the `exp`/`sig` pair a temporary URL mints
### (./sign, keys from void/security), and an expired or tampered link
### is a 403 that does not say which. Off (the default), the prefix is
### public — a storefront's product images — and a signed link still
### verifies, it is just not demanded.
###
### The route carries no policy of its own, because this plugin cannot
### know the policy names of the application it lands in — but it will
### carry the one the application names. `[:storage :serve :policy]`
### becomes the route's `:void.authz/policy`, which is the only line a
### composition under `[:authz :default :deny]` needs; without it such
### a composition refuses to start, naming this route, and that is the
### right refusal — under a deny posture silence must not mean public.
### A `:public` there is a decision somebody wrote down.

(import void/core/plugin :as plugin)
(import void/http/errors :as errors)
(import void/http/router :as router)
(import void/http/static :as static)
(import ./key :as key)
(import ./sign :as sign)

(def defaults
  "What serving falls back to when [:storage :serve] says nothing."
  {:prefix "/storage"
   :signed false
   :max-file-size 10485760})

(var settings
  "The resolved serve settings — read at :before-start, because the
  handler runs on the hot path and has no business reaching into the
  boot value there."
  defaults)

(var root
  "The local root files are served from ([:storage :local :root])."
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :storage-http/capture-config
   :doc "Read the [:storage] slice once, before the route table is built"
   :fn (fn capture [boot]
         (def slice (get-in boot [:config :values :storage] {}))
         (set settings (merge defaults (get slice :serve {})))
         (set root (get-in slice [:local :root] "storage")))})

(defn serve-file
  ``The handler: decode the splat, validate it as a key (the traversal
  rules live there), demand the signature when the prefix is private,
  and hand the path to static/file-response — 304, 206 and 416
  included. Everything that is not a readable object is the same 404.``
  [req]
  (def k (static/path-decode (get-in req [:params :key] "")))
  (unless (and k (key/valid? k))
    (errors/abort 404))
  (when (settings :signed)
    (unless (sign/valid? k
                         (get-in req [:query "exp"])
                         (get-in req [:query "sig"]))
      (errors/abort 403 "this link is expired or not signed")))
  (or (static/file-response req (string root "/" k)
                            {:max-file-size (settings :max-file-size)})
      (errors/abort 404)))

(defn- own-routes
  # a function of boot, not a value: the mount prefix is configuration,
  # which is not known when this manifest freezes (the ADR-0029 §12
  # form)
  [_boot]
  (router/routes (if-let [policy (settings :policy)]
                   {:void.authz/policy policy}
                   {})
    (router/GET (string (settings :prefix) "/*key") 'serve-file
                {:name :void.storage/serve})))

(plugin/defplugin void/storage-http
  :doc "Serving the local storage store over HTTP: one GET route under [:storage :serve :prefix], through the static machinery (etag/range), public by default and signature-gated with [:storage :serve :signed] true."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/storage ">=0.0.1" :void/http ">=0.0.1"}
  :contributes {:void.http/route-source
                [{:name :void/storage-http
                  :routes own-routes
                  :env (router/env-ref (curenv))}]})
