### void/ws-htmx — the htmx ws-extension, from the server's side
### (SPEC §5.6).
###
### htmx's `ws` extension makes a websocket look like the rest of htmx:
### an element opens the socket (`hx-ext="ws" ws-connect="/live"`), a
### form inside it sends its fields as JSON (`ws-send`), and **anything
### the server pushes down the socket is swapped into the page
### out-of-band** — by `id`, exactly like the OOB half of an ordinary
### htmx response. So the server side of it is not a protocol at all:
### it is `void/html` hiccup with `hx-swap-oob` on it, which
### `void/htmx` has been able to produce since wave 1.
###
### That is why this is fifty lines and not a package: the fragment a
### handler pushes over a socket is the same value it would have
### returned from a route, marked the same way, rendered by the same
### engine.
###
###     (defn chat [req]
###       (ws/accept req
###         {:rooms [:room]
###          :on-message
###          (fn [conn msg]
###            (def fields (wshtmx/fields msg))
###            (wshtmx/broadcast! :room
###              [:div {:id "messages" :hx-swap-oob "beforeend"}
###               [:p (fields :message)]]))}))
###
### It is a separate plugin from `void/ws` for the reason
### `void/cache-http` is separate from `void/cache`: an application
### whose sockets carry JSON should not have to compose a template
### engine to open one.

(import void/core/plugin :as plugin)
(import void/html/hiccup :as hiccup)
(import void/htmx/hx :as hx)
(import ./init :as ws)
(import ./conn :as conn)
(import ./rooms :as rooms)

(def header-field
  ``The key htmx puts its request headers under when a `ws-send`
  element serialises a form. Everything beside it is a form field.

  It is a keyword because the JSON arrives decoded the way every other
  request body in void does (`void/rest` reads one the same way): a
  field named `message` in the HTML is `:message` here.``
  :HEADERS)

(defn fields
  ``The form fields out of an htmx `ws-send` message: the decoded JSON
  object without htmx's own `HEADERS` entry. Returns nil when the
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
  "The `HEADERS` object htmx sends alongside the fields (HX-Trigger,
  HX-Target and friends), or nil."
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

(defn fragment
  ``One htmx-swappable payload: hiccup marked for an out-of-band swap
  and rendered to HTML. A string or buffer passes through untouched —
  a caller that has already rendered (or already marked) knows what it
  is doing.

  `swap` is a `void/htmx` swap style for the mark (`hx/oob`'s default
  is plain `true`, which htmx reads as "replace the element with this
  id"); an element that already carries `hx-swap-oob` keeps what it
  says.``
  [content &opt swap]
  (def marked (oob-marked content swap))
  (if (or (string? marked) (buffer? marked))
    (string marked)
    (string (hiccup/render marked))))

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
  ``The attributes that open the socket on an element:

      [:div (wshtmx/connect-attrs "/live") ...]
      # -> hx-ext="ws" ws-connect="/live"

  The URL is relative or absolute; htmx works out the scheme, which is
  why nothing here says `ws://` (and why a deployment behind a TLS
  relay needs no change on this side — ADR-0010).``
  [url & kvs]
  (merge @{"hx-ext" "ws" "ws-connect" url} (hx/attrs ;kvs)))

(defn send-attrs
  ``The attribute that sends an element's form over the open socket:

      [:form (merge (wshtmx/send-attrs) {:id "say"}) ...]
      # -> ws-send="true"``
  [& kvs]
  (merge @{"ws-send" "true"} (hx/attrs ;kvs)))

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/ws-htmx
  :doc "The server side of htmx's ws extension: a hiccup fragment marked for an out-of-band swap, rendered once and pushed down the socket — the same value, the same mark and the same renderer an ordinary htmx response uses."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/ws ">=0.0.1"
             :void/html ">=0.0.1" :void/htmx ">=0.0.1"})
