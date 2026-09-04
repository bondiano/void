### void/rest/problem — RFC 7807 / RFC 9457 problem+json responses.
###
### Every REST failure is one media type: application/problem+json with
### the standard members (type, title, status, detail, instance) plus
### whatever extension members the caller adds. Validation failures use
### the conventional "errors" extension — one entry per schema error,
### each carrying a JSON pointer built from the schema error path and
### the human-readable message from schema/error-str. `from-error` maps
### the structured throws of void/http/errors (abort, panics) onto a
### problem so the error-renderer contribution in init can answer API
### clients without ever leaking an HTML error page at them.
###
### An error envelope (void/core/errors) maps by its parts: the kind
### becomes the "kind" extension member on a 4xx (a client branches on
### it the way a handler does; a 5xx keeps its internals), the message
### the "detail", `:data {:problem ...}` merges in as extension
### members, and a :void.schema/invalid carries its schema errors in
### `:data {:errors :in}`, which land in the conventional "errors".

(import spork/json)
(import void/core/errors :as errors)
(import void/core/schema :as schema)
(import void/http/wire :as wire)
(import void/http/ring :as ring)

(def media-type
  "The problem+json media type."
  "application/problem+json")

(defn- escape-pointer-token [t]
  (->> (string t)
       (string/replace-all "~" "~0")
       (string/replace-all "/" "~1")))

(defn pointer
  ``A schema error path as a JSON pointer (RFC 6901):
  [:tags 3] -> "/tags/3", [] -> "".``
  [path]
  (string/join (map |(string "/" (escape-pointer-token $)) path) ""))

(defn body
  ``The problem members table for a status: {"type" "about:blank"
  "title <status message>" "status" N} merged with the extension (and
  standard-member override) table `ext`.``
  [status &opt ext]
  (merge @{"type" "about:blank"
           "title" (get wire/status-messages status "Error")
           "status" status}
         (or ext @{})))

(defn response
  ``An application/problem+json response:

      (problem/response 404)
      (problem/response 403 {"detail" "order belongs to another brand"})``
  [status &opt ext headers]
  (ring/response status
                 (json/encode (body status ext))
                 (merge @{"content-type" media-type}
                        (or headers @{}))))

(defn validation-errors
  "Schema errors as the conventional \"errors\" extension member:
  [{\"pointer\" \"/tags/3\" \"detail\" \"expected :keyword...\"} ...]."
  [errors]
  (map (fn [e] @{"pointer" (pointer (e :path))
                 "detail" (schema/error-str e)})
       errors))

(defn validation
  ``The problem for a batch of schema/check errors. `in` names the
  request part that failed (:body :query :params :headers) and lands in
  "detail" plus each error entry.``
  [status in errors]
  (response status
            @{"detail" (string/format "invalid request %s" (string in))
              "errors" (map |(merge $ @{"in" (string in)})
                            (validation-errors errors))}))

(defn from-error
  ``Map a caught error value onto a problem response — the renderer
  side of void/http/errors: an envelope (or a v1 `(abort 422 "msg")`)
  keeps its status and message, a :problem member (on the value, or
  under :data) merges in as extension members, a schema violation
  becomes "errors", and anything else is the bare status problem. On a
  4xx the kind travels as "kind"; 500 details stay hidden unless ctx
  :dev.``
  [err ctx]
  (def status (ctx :status))
  (def env (errors/of err))
  (def kind (errors/kind env))
  (def ext @{})
  (when-let [p (or (when (dictionary? err) (get err :problem))
                   (get (errors/data env) :problem))]
    (merge-into ext p))
  (when (get env :message)
    (put ext "detail" (errors/message env)))
  (when (= :void.schema/invalid kind)
    (def d (errors/data env))
    (def in (string (get d :in "body")))
    (put ext "detail" (string/format "invalid request %s" in))
    (put ext "errors" (map |(merge $ @{"in" in})
                           (validation-errors (get d :errors [])))))
  (when (and (< status 500) (not= :void.http/abort kind) (not= :void/panic kind))
    (put ext "kind" (string kind)))
  (when (and (>= status 500) (not (ctx :dev)))
    (put ext "detail" nil))
  (when (and (>= status 500) (ctx :dev) (nil? (ext "detail")))
    (put ext "detail" (if (bytes? err) (string err) (describe err))))
  (response status ext))
