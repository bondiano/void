### void/ws-htmx — the htmx ws-extension, from the server's side
### (SPEC §5.6, ADR-0028, ADR-0041).
###
### htmx's `hx-ws` extension makes a websocket look like the rest of
### htmx: an element opens the socket (`hx-ws:connect="/live"`), a form
### inside it sends its fields as JSON (`hx-ws:send`), and what the
### server pushes down the socket is swapped into the page. So the
### server side of it is not a protocol at all: it is `void/html`
### hiccup, rendered by the engine a page uses.
###
### A pushed fragment finds its place one of two ways, and that is the
### whole API surface here:
###
###   * **by its own id** — hiccup marked `hx-swap-oob`, exactly like
###     the OOB half of an ordinary htmx response;
###   * **by a target you name** — htmx 4's JSON control message
###     (`{"content": ..., "target": ..., "swap": ...}`), for content
###     that has no id of its own to be found by.
###
### Both come out of ./fragment, and which one it is is decided by
### whether the swap argument names a `:target`.
###
###     (defn chat [req]
###       (ws/accept req
###         {:rooms [:room]
###          :on-message
###          (fn [conn msg]
###            (def fields (wshtmx/fields msg))
###            (wshtmx/broadcast! :room
###              [:p (fields :message)]
###              {:target "#messages" :swap :before-end}))}))
###
### The page has to load the extension beside htmx itself — htmx 4
### removed `hx-ext`, so the script tag *is* the opt-in:
###
###     [:script {:src "https://unpkg.com/htmx.org@4.0.0"}]
###     [:script {:src "https://unpkg.com/htmx.org@4.0.0/dist/ext/hx-ws.js"}]
###
### It is a separate plugin from `void/ws` for the reason
### `void/cache-http` is separate from `void/cache`: an application
### whose sockets carry JSON should not have to compose a template
### engine to open one.

(import void/core/plugin :as plugin)
(import void/html/hiccup :as hiccup)
(import void/htmx/hx :as hx)
(import spork/json)
(import ./init :as ws)
(import ./conn :as conn)
(import ./rooms :as rooms)

(def header-field
  ``The key htmx puts its request metadata under when an `hx-ws:send`
  element serialises a form. Everything beside it is a form field.

  It is `:headers` and lowercase since htmx 4 (ADR-0041; the envelope
  spelled it `HEADERS` before), and a keyword because the JSON arrives
  decoded the way every other request body in void does (`void/rest`
  reads one the same way): a field named `message` in the HTML is
  `:message` here.``
  :headers)

(defn fields
  ``The form fields out of an htmx `hx-ws:send` message: the decoded
  JSON object without htmx's own `headers` entry. Returns nil when the
  message is not one — a socket is open to whoever holds it, and a
  payload that is not the envelope htmx sends is a message to ignore
  rather than an exception in the connection fiber.``
  [message]
  (when-let [value (ws/json-body message)]
    (when (dictionary? value)
      (def out (merge @{} value))
      (put out header-field nil)
      out)))

(defn headers
  ``The `headers` object htmx sends alongside the fields (HX-Request,
  HX-Request-Type, HX-Source, HX-Target and friends), or nil.``
  [message]
  (when-let [value (ws/json-body message)]
    (when (dictionary? value)
      (get value header-field))))

(defn- oob-marked [node swap]
  (cond
    (or (string? node) (buffer? node)) node
    (and (tuple? node) (keyword? (first node)))
    (do
      (def attrs (get node 1))
      (unless (and (dictionary? attrs)
                   (or (get attrs :id) (get attrs "id")
                       (get attrs :hx-swap-oob) (get attrs "hx-swap-oob")))
        (errorf (string "an out-of-band swap finds its target by id, and %q has "
                        "none — give the element an :id (or mark it yourself "
                        "with :hx-swap-oob)")
                (first node)))
      (if (or (get attrs :hx-swap-oob) (get attrs "hx-swap-oob"))
        node
        (hx/oob node swap)))
    (indexed? node) (map |(oob-marked $ swap) node)
    (errorf "a websocket fragment is hiccup or ready HTML, got %q" node)))

(defn- rendered [content]
  (if (or (string? content) (buffer? content))
    (string content)
    (string (hiccup/render content))))

(defn- control-message
  "htmx 4's JSON message: the HTML plus where it goes."
  [content spec]
  (def out @{"content" (rendered content)
             "target" (get spec :target)})
  (when-let [swap (get spec :swap)] (put out "swap" (hx/swap-style swap)))
  (when-let [select (get spec :select)] (put out "select" select))
  (json/encode out))

(defn fragment
  ``One htmx-swappable payload, in whichever of the two forms the swap
  argument asks for.

  Without a `:target` it is **hiccup marked for an out-of-band swap**
  and rendered to HTML: `swap` is a `void/htmx` swap style for the
  mark (`hx/oob`'s default is plain `true`, which htmx reads as
  "replace the element with this id"), an element that already carries
  `hx-swap-oob` keeps what it says, and an element with neither an id
  nor a mark is an error rather than a message that lands nowhere. A
  string or buffer passes through untouched — a caller that has
  already rendered (or already marked) knows what it is doing.

      (wshtmx/fragment [:li {:id "m-1"} "hi"])
      (wshtmx/fragment [:span {:id "a"} 1] :inner-html)

  With a dictionary naming a `:target` it is instead **htmx 4's JSON
  control message** — `{"content", "target", "swap"?, "select"?}` —
  and the content needs no id, because the message says where it goes:

      (wshtmx/fragment [:p "good evening"]
                       {:target "#messages" :swap :before-end})``
  [content &opt swap]
  (if (and (dictionary? swap) (get swap :target))
    (control-message content swap)
    (rendered (oob-marked content swap))))

(defn send!
  "Render a fragment and send it to one connection."
  [c content &opt swap]
  (conn/send! c (fragment content swap)))

(defn broadcast!
  ``Render a fragment once and send it to every connection in a room —
  the rendering happens here, not per member, for the same reason the
  framing does (./rooms).``
  [name content &opt swap opts]
  (rooms/broadcast! (ws/registry) name (fragment content swap) opts))

# -- the attributes on the page ------------------------------------------

(defn connect-attrs
  ``The attribute that opens the socket on an element:

      [:div (wshtmx/connect-attrs "/live") ...]
      # -> hx-ws:connect="/live"

  There is no `hx-ext` beside it: htmx 4 removed the attribute, and an
  extension is loaded by its script tag alone (ADR-0041) — see the
  header of this file.

  The URL is relative or absolute; htmx works out the scheme, which is
  why nothing here says `ws://` (and why a deployment behind a TLS
  relay needs no change on this side — ADR-0010).``
  [url & kvs]
  (merge @{"hx-ws:connect" url} (hx/attrs ;kvs)))

(defn send-attrs
  ``The attribute that sends an element's form over the open socket:

      [:form (merge (wshtmx/send-attrs) {:id "say"}) ...]
      # -> hx-ws:send="true"``
  [& kvs]
  (merge @{"hx-ws:send" "true"} (hx/attrs ;kvs)))

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/ws-htmx
  :doc "The server side of htmx's ws extension: a hiccup fragment marked for an out-of-band swap, rendered once and pushed down the socket — the same value, the same mark and the same renderer an ordinary htmx response uses."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/ws ">=0.0.1"
             :void/html ">=0.0.1" :void/htmx ">=0.0.1"})
