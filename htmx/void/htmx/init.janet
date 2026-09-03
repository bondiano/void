### void/htmx — htmx integration plugin.
###
### Three small pieces over void/http + void/html. Request side:
### predicates over the HX-* headers htmx sends. Response side: the
### HX-Trigger / HX-Redirect / HX-Retarget response-header helpers and
### hx-attribute builders (./hx). In between: the :void.htmx/partial
### route metadata key — a route marked with it answers a partial
### request with the fragment alone, no layout. The middleware sits
### deeper in the chain (phase 9500) than void/html's render middleware
### (9000): the chain unwinds innermost-first, so the layout is
### stripped from the still-unrendered view response before the engine
### runs — full pages and fragments from one handler, decided per
### request.
###
### What decides is HX-Request-Type, which htmx 4 sends on every
### request: "partial" when the swap lands in some element, "full" when
### it lands in the body or an hx-select cuts the response up. So the
### three cases that used to need three rules are one header read — a
### boosted navigation and a history restore both target the body and
### both say "full", and both get their layout back.

(import void/core/plugin :as plugin)
(import void/http/ring :as ring)
(import void/http/wire :as wire)
(import spork/json)
(import ./hx :as hx)

# -- request side --------------------------------------------------------

(defn- header-true? [req name]
  (= "true" (ring/request-header req name)))

(defn request?
  "Did htmx issue this request (HX-Request)?"
  [req]
  (header-true? req "hx-request"))

(defn boosted?
  "Is this a boosted (hx-boost) request?"
  [req]
  (header-true? req "hx-boosted"))

(defn history-restore?
  "Is htmx refetching a page for the history stack
  (HX-History-Restore-Request)? htmx 4 keeps no page cache — going
  back asks the server again, and asks for the whole page."
  [req]
  (header-true? req "hx-history-restore-request"))

(defn request-type
  ``How much of the page this request is for (HX-Request-Type):
  "partial" when the swap targets an element, "full" when it targets
  the body or an hx-select picks the response apart. nil when the
  request did not come from htmx.``
  [req]
  (ring/request-header req "hx-request-type"))

(defn partial-request?
  "Is this request for a fragment (HX-Request-Type: partial)? The
  question the :void.htmx/partial middleware asks."
  [req]
  (= "partial" (request-type req)))

(defn full-request?
  "Is this htmx request for a whole page (HX-Request-Type: full) — a
  body-targeted swap, a boosted navigation, a history restore?"
  [req]
  (= "full" (request-type req)))

(defn target
  ``The swap target as htmx names it (HX-Target): `tag#id`, e.g.
  "div#results", or the bare tag name when the element has no id.``
  [req]
  (ring/request-header req "hx-target"))

(defn source
  ``The element that issued the request (HX-Source), in the same
  `tag#id` form as target — "button#save".``
  [req]
  (ring/request-header req "hx-source"))

(defn element-id
  ``The id out of htmx's `tag#id` identifier, percent-decoded; nil for
  an element that has none:

      (htmx/element-id "div#results")  # -> "results"
      (htmx/element-id "button")       # -> nil``
  [ident]
  (when ident
    (when-let [i (string/find "#" ident)]
      (wire/url-decode (string/slice ident (inc i))))))

(defn target-id
  "The id of the swap target, or nil — (element-id (target req))."
  [req]
  (element-id (target req)))

(defn source-id
  "The id of the element that issued the request, or nil."
  [req]
  (element-id (source req)))

(defn current-url
  "The browser URL when the request fired (HX-Current-URL), or nil."
  [req]
  (ring/request-header req "hx-current-url"))

# -- response side -------------------------------------------------------

(defn trigger
  ``Fire client-side events from the response (HX-Trigger). Events are
  names (string/keyword) or dictionaries {event payload}; any payload
  switches the header to its JSON form, which htmx reads as HCON:

      (htmx/trigger resp :order-created)
      (htmx/trigger resp {:show-toast {:level "info" :text "saved"}})

  A payload's :target names another element to fire the event on —
  the event reaches it instead of the element that made the request.``
  [resp & events]
  (def all
    (mapcat (fn [e]
              (cond
                (dictionary? e) (pairs e)
                [[(string e) nil]]))
            events))
  (when (empty? all)
    (error "htmx/trigger needs at least one event"))
  (ring/header resp "hx-trigger"
               (if (some |(not (nil? ($ 1))) all)
                 (json/encode (tabseq [[name payload] :in all]
                                (string name) (if (nil? payload) {} payload)))
                 (string/join (map |(string ($ 0)) all) ", "))))

(defn redirect
  "Client-side redirect without a full reload (HX-Redirect)."
  [resp url]
  (ring/header resp "hx-redirect" url))

(defn location
  "Client-side navigation (HX-Location): a URL string or a dictionary
  with :path plus swap options — JSON-encoded."
  [resp to]
  (ring/header resp "hx-location" (if (dictionary? to) (json/encode to) to)))

(defn refresh
  "Ask the client for a full page refresh (HX-Refresh)."
  [resp]
  (ring/header resp "hx-refresh" "true"))

(defn push-url
  "Push a URL into the history (HX-Push-Url); false prevents the
  push."
  [resp url]
  (ring/header resp "hx-push-url" (if (false? url) "false" url)))

(defn replace-url
  "Replace the current history URL (HX-Replace-Url); false prevents
  the replacement."
  [resp url]
  (ring/header resp "hx-replace-url" (if (false? url) "false" url)))

(defn retarget
  "Override the swap target with a CSS selector (HX-Retarget)."
  [resp selector]
  (ring/header resp "hx-retarget" selector))

(defn reswap
  "Override the swap style (HX-Reswap) — a swap keyword or verbatim
  string, see hx/swap-style."
  [resp style]
  (ring/header resp "hx-reswap" (hx/swap-style style)))

(defn reselect
  "Choose a part of the response to swap in (HX-Reselect)."
  [resp selector]
  (ring/header resp "hx-reselect" selector))

(defn stop-polling
  ``Answer a poll with the end of the poll. htmx 4 has no status code
  for this — an `every` trigger runs as long as its element is in the
  document — so the response says it with a swap instead: an empty
  body swapped as `delete` removes the polling element, and the
  interval goes with it.

  A body may be given to leave something in its place, in which case
  the swap is the ordinary outerHTML: what replaces the element is not
  polling.``
  [&opt body]
  (def resp (ring/html 200 (or body "")))
  (reswap resp (if body :outer-html :delete)))

# -- the partial middleware ----------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.htmx/partial
   :schema :boolean
   :doc "Answer HX-Request-Type: partial with the fragment alone — the view response's layout is stripped before rendering"
   :merge :replace})

(plugin/contribute! :void.http/middleware
  {:name :void.htmx/partial
   :phase 9500
   :doc "Strip the layout from view responses to partial htmx requests on routes marked :void.htmx/partial"
   :when |(get $ :void.htmx/partial)
   :wrap (fn [handler]
           (fn htmx-partial [req]
             (def resp (handler req))
             (when (and (dictionary? resp)
                        (not (nil? (get resp :void.html/content)))
                        (partial-request? req))
               (put resp :void.html/layout nil))
             resp))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/htmx
  :doc "htmx 4 integration: hx-attribute builders, HX-* request predicates and response headers (HX-Trigger, HX-Redirect, ...), OOB and <hx-partial> swaps, and fragment-without-layout answers on routes marked :void.htmx/partial."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1" :void/html ">=0.0.1"})
