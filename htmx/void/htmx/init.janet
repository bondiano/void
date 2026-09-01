### void/htmx — htmx integration plugin (SPEC.md §5.5).
###
### Three small pieces over void/http + void/html. Request side:
### predicates over the HX-* headers htmx sends. Response side: the
### HX-Trigger / HX-Redirect / HX-Retarget response-header helpers and
### hx-attribute builders (./hx). In between: the :void.htmx/partial
### route metadata key — a route marked with it answers an HX-Request
### with the fragment alone, no layout. The middleware sits deeper in
### the chain (phase 9500) than void/html's render middleware (9000):
### the chain unwinds innermost-first, so the layout is stripped from
### the still-unrendered view response before the engine runs — full
### pages and fragments from one handler, decided per request. A
### history restore request (HX-History-Restore-Request) keeps the
### layout: htmx asks for a full page there.

(import void/core/plugin :as plugin)
(import void/http/ring :as ring)
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
  "Is htmx restoring history (needs a full page, not a fragment)?"
  [req]
  (header-true? req "hx-history-restore-request"))

(defn target
  "The id of the target element (HX-Target), or nil."
  [req]
  (ring/request-header req "hx-target"))

(defn trigger-id
  "The id of the triggering element (HX-Trigger), or nil."
  [req]
  (ring/request-header req "hx-trigger"))

(defn trigger-name
  "The name of the triggering element (HX-Trigger-Name), or nil."
  [req]
  (ring/request-header req "hx-trigger-name"))

(defn prompt
  "The user's hx-prompt answer (HX-Prompt), or nil."
  [req]
  (ring/request-header req "hx-prompt"))

(defn current-url
  "The browser URL when the request fired (HX-Current-URL), or nil."
  [req]
  (ring/request-header req "hx-current-url"))

# -- response side -------------------------------------------------------

(defn- trigger-header [resp header events]
  (def all
    (mapcat (fn [e]
              (cond
                (dictionary? e) (pairs e)
                [[(string e) nil]]))
            events))
  (when (empty? all)
    (error "htmx/trigger needs at least one event"))
  (ring/header resp header
               (if (some |(not (nil? ($ 1))) all)
                 (json/encode (tabseq [[name payload] :in all]
                                (string name) (if (nil? payload) {} payload)))
                 (string/join (map |(string ($ 0)) all) ", "))))

(defn trigger
  ``Fire client-side events from the response (HX-Trigger). Events are
  names (string/keyword) or dictionaries {event payload}; any payload
  switches the header to its JSON form:

      (htmx/trigger resp :order-created)
      (htmx/trigger resp {:show-toast {:level "info" :text "saved"}})``
  [resp & events]
  (trigger-header resp "hx-trigger" events))

(defn trigger-after-settle
  "HX-Trigger-After-Settle — as trigger, after the settle step."
  [resp & events]
  (trigger-header resp "hx-trigger-after-settle" events))

(defn trigger-after-swap
  "HX-Trigger-After-Swap — as trigger, after the swap step."
  [resp & events]
  (trigger-header resp "hx-trigger-after-swap" events))

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
  "The 286 response that tells a polling element to stop."
  [&opt body]
  (ring/html 286 (or body "")))

# -- the partial middleware ----------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.htmx/partial
   :schema :boolean
   :doc "Answer HX-Request with the fragment alone — the view response's layout is stripped before rendering"
   :merge :replace})

(plugin/contribute! :void.http/middleware
  {:name :void.htmx/partial
   :phase 9500
   :doc "Strip the layout from view responses to htmx requests on routes marked :void.htmx/partial"
   :when |(get $ :void.htmx/partial)
   :wrap (fn [handler]
           (fn htmx-partial [req]
             (def resp (handler req))
             (when (and (dictionary? resp)
                        (not (nil? (get resp :void.html/content)))
                        (request? req)
                        (not (history-restore? req)))
               (put resp :void.html/layout nil))
             resp))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/htmx
  :doc "htmx integration: hx-attribute builders, HX-* request predicates and response headers (HX-Trigger, HX-Redirect, ...), OOB swap marking, and fragment-without-layout answers on routes marked :void.htmx/partial."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1" :void/html ">=0.0.1"})
