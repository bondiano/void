### void/html/hiccup — the hiccup pipeline.
###
### Views are plain data, rendered here in one pass: a tuple whose head
### is a function is a component call — the function is applied to the
### rest of the tuple and the result is rendered in its place, so
### layouts and partials are ordinary functions returning hiccup. A
### keyword-headed tuple is an element [tag attrs? & children]; any
### other tuple and every array is a fragment (a component's & children
### rest argument arrives as one); strings and numbers are escaped
### text; nil disappears; (raw "...") splices unescaped HTML.
###
### Two things a leaf may not be. A dictionary outside attribute
### position is an error, and so is a **bare function**: under
### spork/htmlgen a function leaf was called with the output buffer as
### its one argument, so `[:div who-bar]` — a component named without
### its brackets — rendered as whatever that function did with a
### buffer, silently. Now it names the function and says to call it.
###
### Attributes are normalized, not just escaped: nil and false drop
### the attribute, true writes it bare (`<input checked>`), a vector
### or dictionary under :class goes through `classes`, a dictionary
### under :style becomes declarations, and a name that HTML could not
### parse as one attribute (a space, a quote, `=`, `>`, `/`) is an
### error rather than a second attribute. Keys render sorted, so the
### same data is the same bytes.

(import spork/json)
(import void/core/util :as util)

# -- escaping ------------------------------------------------------------

(def- escape-peg
  (peg/compile
    ~(% (any (+ (* "&" (constant "&amp;"))
                (* "\"" (constant "&quot;"))
                (* "<" (constant "&lt;"))
                (* ">" (constant "&gt;"))
                (* "'" (constant "&#39;"))
                '1)))))

(defn escape
  "Escape a string for HTML text/attribute content."
  [x]
  (in (peg/match escape-peg (string x)) 0))

# -- raw -----------------------------------------------------------------

(defn raw
  ``(raw text) — splice unescaped HTML. The value is data (a struct
  with one key), not a function, so a renderer can tell it from a
  component somebody forgot to call.``
  [text]
  {:void.html/raw (string text)})

(defn raw?
  "Is this a `raw` value?"
  [x]
  (and (struct? x) (string? (get x :void.html/raw))))

(def doctype
  "The HTML5 doctype, ready to splice into a fragment."
  (raw "<!DOCTYPE html>"))

# -- classes and styles --------------------------------------------------

(defn classes
  ``Build a class attribute value from mixed pieces: strings and
  keywords are included, nil/false are skipped, an indexed value is
  flattened, a dictionary contributes the keys whose values are truthy:

      (classes "btn" (when big? :btn-lg) {:active active?})``
  [& pieces]
  (def out @[])
  (each p pieces
    (cond
      (or (nil? p) (false? p)) nil
      (dictionary? p) (each k (sorted (keys p))
                        (when (p k) (array/push out (string k))))
      (indexed? p) (let [s (classes ;p)]
                     (unless (empty? s) (array/push out s)))
      (array/push out (string p))))
  (string/join out " "))

(defn- style-str
  "A :style dictionary as declarations — {:color \"red\" :margin 0}
  -> \"color:red;margin:0\". Sorted, nil values dropped."
  [d]
  (string/join
    (seq [k :in (sorted (keys d)) :let [v (d k)] :when (not (nil? v))]
      (string k ":" v))
    ";"))

# -- attributes ----------------------------------------------------------

(def- attr-name-peg
  # HTML's own rule: an attribute name is anything but controls,
  # space, the two quotes, `>`, `/` and `=` — which keeps `hx-on:click`,
  # `@click`, `data-signals__ifmissing` and `x-bind:class` all legal
  (peg/compile ~(* (some (+ (range "\x21\x21") (range "\x23\x26") (range "\x28\x2e")
                            (range "\x30\x3c") (range "\x3f\x7e") (range "\x80\xff")))
                   -1)))

(defn- attr-name [k]
  (def s (string k))
  (unless (peg/match attr-name-peg s)
    (errorf "hiccup attribute name %q is not one attribute — no space, quote, `=`, `>` or `/`" s))
  s)

(defn- attr-value [k v]
  (cond
    (and (= k :class) (or (indexed? v) (dictionary? v))) (classes v)
    (and (= k :style) (dictionary? v)) (style-str v)
    (string v)))

(defn- render-attrs [buf attrs]
  (each k (sorted-by string (keys attrs))
    (def v (attrs k))
    (cond
      (or (nil? v) (false? v)) nil
      (true? v) (buffer/push buf " " (attr-name k))
      (buffer/push buf " " (attr-name k) `="` (escape (attr-value k v)) `"`))))

# -- rendering -----------------------------------------------------------

(def- self-close-tags
  {:area true :base true :br true :col true :embed true :hr true :img true
   :input true :link true :meta true :param true :source true :track true
   :wbr true :command true :keygen true :menuitem true})

(defn- attrs? [x]
  (and (dictionary? x) (not (raw? x))))

(var- render1 nil)

(defn- render-element [buf tag node]
  (def attrs (get node 1))
  (def has-attrs (attrs? attrs))
  (buffer/push buf "<" (string tag))
  (when has-attrs (render-attrs buf attrs))
  (if (get self-close-tags (keyword tag))
    (buffer/push buf "/>")
    (do
      (buffer/push buf ">")
      (each child (tuple/slice node (if has-attrs 2 1)) (render1 buf child))
      (buffer/push buf "</" (string tag) ">"))))

(defn- render-node [buf node]
  (cond
    (nil? node) nil
    (or (string? node) (buffer? node) (number? node) (boolean? node))
    (buffer/push buf (escape node))

    (raw? node) (buffer/push buf (node :void.html/raw))

    (tuple? node)
    (let [head (first node)]
      (cond
        (util/callable? head) (render1 buf (head ;(tuple/slice node 1)))
        (or (keyword? head) (symbol? head)) (render-element buf head node)
        (each child node (render1 buf child))))

    (or (array? node) (fiber? node)) (each child node (render1 buf child))

    (util/callable? node)
    (errorf "function leaf in hiccup: %q — a component is called as [f ...], and unescaped HTML is (raw ...)"
            node)

    (dictionary? node)
    (errorf "dictionary outside attribute position in hiccup: %q" node)

    (errorf "cannot render %q as hiccup" node)))

(set render1 render-node)

(defn render
  "Render hiccup into `buf` (a fresh buffer by default). Returns the
  buffer."
  [data &opt buf]
  (default buf @"")
  (render1 buf data)
  buf)

(defn render-string
  "Render hiccup to a string."
  [data]
  (string (render data)))

# -- documents and data islands ------------------------------------------

(defn html5
  ``A full HTML5 document fragment: the doctype followed by
  [:html attrs & children]. `attrs` is optional:

      (html5 {:lang "en"} [:head ...] [:body ...])``
  [& forms]
  (def [attrs children]
    (if (attrs? (first forms))
      [(first forms) (drop 1 forms)]
      [{} forms]))
  @[doctype [:html attrs ;children]])

(defn json-script
  ``A data island: `<script type="application/json" id=...>` carrying
  a value for a script on the page to read with JSON.parse. The
  encoding escapes `<`, `>` and `&` as \u-sequences, so a string in
  the data cannot close the script tag — which is what makes this
  safe where (raw (json/encode v)) is not.``
  [id value]
  (def text
    (->> (json/encode value)
         (string/replace-all "<" "\\u003c")
         (string/replace-all ">" "\\u003e")
         (string/replace-all "&" "\\u0026")))
  [:script {:type "application/json" :id id} (raw text)])
