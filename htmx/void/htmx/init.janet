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
(import void/html/init :as html)
(import spork/json)
(import ./hx :as hx)

# -- request side --------------------------------------------------------

(defn- header-true?
  {:params [@{:headers @{:string :any} & r} :string] :ret :boolean :narrows :any}
  "True when request header `name` is exactly \"true\" — the shape
  every boolean HX-* request header takes."
  [req name]
  (= "true" (ring/request-header req name)))

(defn request?
  {:params [@{:headers @{:string :any} & r}] :ret :boolean :narrows :any}
  "Did htmx issue this request (HX-Request)?"
  [req]
  (header-true? req "hx-request"))

(defn boosted?
  {:params [@{:headers @{:string :any} & r}] :ret :boolean :narrows :any}
  "Is this a boosted (hx-boost) request?"
  [req]
  (header-true? req "hx-boosted"))

(defn history-restore?
  {:params [@{:headers @{:string :any} & r}] :ret :boolean :narrows :any}
  "Is htmx refetching a page for the history stack
  (HX-History-Restore-Request)? htmx 4 keeps no page cache — going
  back asks the server again, and asks for the whole page."
  [req]
  (header-true? req "hx-history-restore-request"))

(defn request-type
  {:params [@{:headers @{:string :any} & r}] :ret (or :string :nil)}
  ``How much of the page this request is for (HX-Request-Type):
  "partial" when the swap targets an element, "full" when it targets
  the body or an hx-select picks the response apart. nil when the
  request did not come from htmx.``
  [req]
  (ring/request-header req "hx-request-type"))

(def partial-request?
  "Is this request for a fragment (HX-Request-Type: partial)? The
  question the :void.htmx/partial middleware asks, and html/page's
  :partial answers — one reader of the header, in void/html."
  html/partial-request?)

(defn full-request?
  {:params [@{:headers @{:string :any} & r}] :ret :boolean :narrows :any}
  "Is this htmx request for a whole page (HX-Request-Type: full) — a
  body-targeted swap, a boosted navigation, a history restore?"
  [req]
  (= "full" (request-type req)))

(defn target
  {:params [@{:headers @{:string :any} & r}] :ret (or :string :nil)}
  ``The swap target as htmx names it (HX-Target): `tag#id`, e.g.
  "div#results", or the bare tag name when the element has no id.``
  [req]
  (ring/request-header req "hx-target"))

(defn source
  {:params [@{:headers @{:string :any} & r}] :ret (or :string :nil)}
  ``The element that issued the request (HX-Source), in the same
  `tag#id` form as target — "button#save".``
  [req]
  (ring/request-header req "hx-source"))

(defn element-id
  {:params [(or :string :nil)] :ret (or :string :nil)}
  ``The id out of htmx's `tag#id` identifier, percent-decoded; nil for
  an element that has none:

      (htmx/element-id "div#results")  # -> "results"
      (htmx/element-id "button")       # -> nil``
  [ident]
  (when ident
    (when-let [i (string/find "#" ident)]
      (wire/url-decode (string/slice ident (inc i))))))

(defn target-id
  {:params [@{:headers @{:string :any} & r}] :ret (or :string :nil)}
  "The id of the swap target, or nil — (element-id (target req))."
  [req]
  (element-id (target req)))

(defn source-id
  {:params [@{:headers @{:string :any} & r}] :ret (or :string :nil)}
  "The id of the element that issued the request, or nil."
  [req]
  (element-id (source req)))

(defn current-url
  {:params [@{:headers @{:string :any} & r}] :ret (or :string :nil)}
  "The browser URL when the request fired (HX-Current-URL), or nil."
  [req]
  (ring/request-header req "hx-current-url"))

# -- response side -------------------------------------------------------

(defn trigger
  {:params [@{:headers @{:string :any} & r} (or :string :keyword {:keyword :any})]
   :ret @{:headers @{:string :any} & r}
   :throws [:string]}
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
  {:params [@{:headers @{:string :any} & r} :string] :ret @{:headers @{:string :any} & r}}
  "Client-side redirect without a full reload (HX-Redirect)."
  [resp url]
  (ring/header resp "hx-redirect" url))

(defn redirect-back
  {:params [@{:headers @{:string :any} & r} :string] :ret @{:headers @{:string :any} & r}}
  ``After a write, send the client to `url`: htmx gets an HX-Redirect
  on an empty 204 (it will not follow a redirect into a swap target),
  a browser gets a 303 — See Other, the status that says "the write
  happened, now GET this" and that no client replays as a POST. The
  shape of every handler that writes and then shows a page.``
  [req url]
  (if (request? req)
    (redirect (ring/response 204 nil @{}) url)
    (ring/redirect url 303)))

(defn location
  {:params [@{:headers @{:string :any} & r} (or {:keyword :any} :string)]
   :ret @{:headers @{:string :any} & r}}
  "Client-side navigation (HX-Location): a URL string or a dictionary
  with :path plus swap options — JSON-encoded."
  [resp to]
  (ring/header resp "hx-location" (if (dictionary? to) (json/encode to) to)))

(defn refresh
  {:params [@{:headers @{:string :any} & r}] :ret @{:headers @{:string :any} & r}}
  "Ask the client for a full page refresh (HX-Refresh)."
  [resp]
  (ring/header resp "hx-refresh" "true"))

(defn push-url
  {:params [@{:headers @{:string :any} & r} (or :string :boolean)]
   :ret @{:headers @{:string :any} & r}}
  "Push a URL into the history (HX-Push-Url); false prevents the
  push."
  [resp url]
  (ring/header resp "hx-push-url" (if (false? url) "false" url)))

(defn replace-url
  {:params [@{:headers @{:string :any} & r} (or :string :boolean)]
   :ret @{:headers @{:string :any} & r}}
  "Replace the current history URL (HX-Replace-Url); false prevents
  the replacement."
  [resp url]
  (ring/header resp "hx-replace-url" (if (false? url) "false" url)))

(defn retarget
  {:params [@{:headers @{:string :any} & r} :string] :ret @{:headers @{:string :any} & r}}
  "Override the swap target with a CSS selector (HX-Retarget)."
  [resp selector]
  (ring/header resp "hx-retarget" selector))

(defn reswap
  {:params [@{:headers @{:string :any} & r} (or :string :keyword)]
   :ret @{:headers @{:string :any} & r}
   :throws [:string]}
  "Override the swap style (HX-Reswap) — a swap keyword or verbatim
  string, see hx/swap-style."
  [resp style]
  (ring/header resp "hx-reswap" (hx/swap-style style)))

(defn reselect
  {:params [@{:headers @{:string :any} & r} :string] :ret @{:headers @{:string :any} & r}}
  "Choose a part of the response to swap in (HX-Reselect)."
  [resp selector]
  (ring/header resp "hx-reselect" selector))

(defn stop-polling
  {:params [:string?] :ret @{:headers @{:string :any} & r} :throws [:string]}
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

# -- the script ----------------------------------------------------------

(def script-src
  ``The one script a framework page takes from a CDN, pinned to the
  exact file — the bare `htmx.org@4.0.0` URL answers with a redirect
  the integrity attribute would still cover, but a pin that names the
  file is a pin a reader can verify.``
  "https://unpkg.com/htmx.org@4.0.0/dist/htmx.min.js")

(def script-integrity
  "sha384 of that file, so a CDN that serves anything else serves
  nothing. It pairs with `script-src` and only with it."
  "sha384-BvJpBiO8Kh31EqtJe5DRIeWrHWnCGkwytKs9NKFi86Hhw96dEqdEMzZDeK9iEGTc")

(defn script-tag
  {:params [(or {:src :string? :integrity :string? & r} :nil)] :ret :tuple}
  ``The <script> that loads htmx, as hiccup for a layout's <head>: the
  pinned file with its integrity hash. Options: :src for a file served
  elsewhere (a self-hosted copy), :integrity for its hash — a :src
  that is not the pin gets no integrity unless one is given, since a
  hash for the wrong file is a script that never loads.``
  [&opt opts]
  (default opts {})
  (def src (get opts :src script-src))
  (def integrity (or (get opts :integrity)
                     (when (= src script-src) script-integrity)))
  [:script (merge {:src src :defer true}
                  (if integrity {:integrity integrity :crossorigin "anonymous"} {}))])

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
