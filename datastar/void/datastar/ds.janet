### void/datastar/ds — data-* attribute helpers.
###
### Builders for Datastar attributes as plain hiccup attribute tables,
### the pose void/htmx/hx struck in wave 1: keywords become data-*
### names (the `:` Datastar puts between a plugin and its argument
### passes through — :on:click -> "data-on:click"), dictionary values
### (data-signals, data-class) are JSON-encoded, and everything
### returns data — merge it into an element's attributes or splice
### several builders together with merge.

(import spork/json)

(defn- attr-value
  {:params [:any] :ret :string}
  "A single attribute value as Datastar wants it on the wire: a
  dictionary JSON-encodes, a boolean stringifies, anything else
  stringifies as-is."
  [v]
  (cond
    (dictionary? v) (string (json/encode v))
    (boolean? v) (string v)
    (string v)))

(defn attrs
  {:params [:any] :ret @{:string :string} :throws [:string]}
  ``Datastar attributes from key-value pairs:

      (ds/attrs :text "$count" :show "$open")
      # -> @{"data-text" "$count" "data-show" "$open"}

      (ds/attrs :signals {:count 0} :on:click "@post('/inc')")
      # -> @{"data-signals" "{\"count\":0}"
      #     "data-on:click" "@post('/inc')"}``
  [& kvs]
  (unless (even? (length kvs))
    (error "ds/attrs takes key-value pairs"))
  (def out @{})
  (each [k v] (partition 2 kvs)
    (put out (string "data-" k) (attr-value v)))
  out)

(defn- camelize
  {:params [:any] :ret :string}
  "A dash-case key as the camelCase Datastar option name — `k` is
  stringified first, so a keyword or a string both work."
  [k]
  (def [head & tail] (string/split "-" (string k)))
  (string head ;(map |(string (string/ascii-upper (string/slice $ 0 1))
                              (string/slice $ 1))
                     tail)))

(defn- option-value
  {:params [:any] :ret :string}
  "An option's literal on the wire: booleans and numbers stay bare,
  anything else is single-quoted as a JS string literal."
  [v]
  (cond
    (or (boolean? v) (number? v)) (string v)
    (string "'" v "'")))

(defn action
  {:params [:keyword :string (or {:keyword :any} :nil)] :ret :string}
  ``A backend action expression for a data-on:* attribute:

      (ds/action :post "/inc")
      # -> "@post('/inc')"
      (ds/action :get "/live" {:open-when-hidden true})
      # -> "@get('/live', {openWhenHidden: true})"

  Option keys camelize the way Datastar spells them; string values are
  quoted, booleans and numbers stay literal.``
  [verb url &opt opts]
  (if (and opts (not (empty? opts)))
    (string "@" verb "('" url "', {"
            (string/join
              (map (fn [k] (string (camelize k) ": " (option-value (opts k))))
                   (sorted (keys opts)))
              ", ")
            "})")
    (string "@" verb "('" url "')")))

(defn signals
  {:params [{:keyword :any}] :ret @{:string :string}}
  "data-signals from a dictionary: (ds/signals {:count 0})."
  [table]
  (attrs :signals table))

(defn on
  {:params [:any :any] :ret @{:string :string}}
  "data-on:<event>: (ds/on :click (ds/action :post \"/inc\"))."
  [event expr]
  (attrs (keyword "on:" event) expr))

(defn load
  {:params [:any] :ret @{:string :string}}
  ``data-init — the attribute Datastar runs when the element mounts,
  which is how a page opens its stream: (ds/load (ds/action :get
  "/live")). It is `data-init`, not `data-on:load`: the bundle has no
  load event, and an attribute it does not know is a page that never
  connects — which inject tests cannot see and a browser can.``
  [expr]
  (attrs :init expr))

(defn bind
  {:params [:any] :ret @{:string :string}}
  "data-bind — two-way binding between an input and a signal."
  [signal]
  (attrs :bind (string signal)))

(defn text
  {:params [:any] :ret @{:string :string}}
  "data-text — the element's text from an expression."
  [expr]
  (attrs :text expr))

(defn show
  {:params [:any] :ret @{:string :string}}
  "data-show — the element's visibility from an expression."
  [expr]
  (attrs :show expr))

(defn indicator
  {:params [:any] :ret @{:string :string}}
  "data-indicator — a signal that is true while a request from this
  element is in flight."
  [signal]
  (attrs :indicator (string signal)))
