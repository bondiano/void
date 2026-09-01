### void/rest/problem — RFC 7807 / RFC 9457 problem+json responses
### (SPEC.md §5.2).
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

(import spork/json)
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
  side of void/http/errors: a structured `(abort 422 "msg")` keeps its
  status and message, a table with a :problem member merges it in, and
  anything else is the bare status problem. 500 details stay hidden
  unless ctx :dev.``
  [err ctx]
  (def status (ctx :status))
  (def ext @{})
  (when (dictionary? err)
    (when-let [p (err :problem)]
      (merge-into ext p))
    (when-let [m (err :message)]
      (put ext "detail" (string m))))
  (when (and (>= status 500) (not (ctx :dev)))
    (put ext "detail" nil))
  (when (and (>= status 500) (ctx :dev) (nil? (ext "detail")))
    (put ext "detail" (if (bytes? err) (string err) (describe err))))
  (response status ext))
