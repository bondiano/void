### void/html/hiccup — the hiccup pipeline (SPEC.md §5.4).
###
### Views are plain data rendered by spork/htmlgen; this module adds
### the component layer on top: a tuple whose head is a function is a
### component call — the function is applied to the rest of the tuple
### and the result is expanded recursively, so layouts and partials are
### ordinary functions returning hiccup. Conventions (htmlgen's, plus
### the component rule): a keyword-headed tuple is an element
### [tag attrs? & children], any other tuple and every array is a
### fragment (a component's & children rest argument arrives as one),
### strings are escaped, nil disappears, (raw "...") splices unescaped
### HTML. Attribute values are escaped; nil-valued attributes are
### dropped before rendering so conditional attributes read as
### (when x {:checked x}).

(import spork/htmlgen)

(def raw
  "(raw text) — splice unescaped HTML (spork/htmlgen)."
  htmlgen/raw)

(def escape
  "Escape a string for HTML text/attribute content (spork/htmlgen)."
  htmlgen/escape)

(def doctype
  "The HTML5 doctype, ready to splice into a fragment."
  htmlgen/doctype-html)

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- clean-attrs
  "Drop nil-valued attributes; keep everything else as-is."
  [attrs]
  (if (some nil? (values attrs))
    (tabseq [[k v] :pairs attrs :when (not (nil? v))] k v)
    attrs))

(defn expand
  ``Expand components in a hiccup tree: every tuple whose head is a
  function is replaced by (head ;rest), recursively, until only
  keyword-tagged elements, fragments and leaves remain. The result is
  plain htmlgen data.``
  [node]
  (cond
    (tuple? node)
    (do
      (def head (first node))
      (cond
        (callable? head)
        (expand (head ;(tuple/slice node 1)))

        (or (keyword? head) (symbol? head))
        (let [attrs (get node 1)]
          (if (dictionary? attrs)
            [head (clean-attrs attrs) ;(map expand (tuple/slice node 2))]
            [head ;(map expand (tuple/slice node 1))]))

        # any other tuple is a fragment — the & children rest argument
        # of a component arrives as one
        (map expand node)))

    (indexed? node) (map expand node)
    node))

(defn render
  "Expand components and render hiccup into `buf` (a fresh buffer by
  default). Returns the buffer."
  [data &opt buf]
  (htmlgen/html (expand data) buf))

(defn render-string
  "Expand and render hiccup to a string."
  [data]
  (string (render data)))

(defn classes
  ``Build a class attribute value from mixed pieces: strings and
  keywords are included, nil/false are skipped, a dictionary
  contributes the keys whose values are truthy:

      (classes "btn" (when big? :btn-lg) {:active active?})``
  [& pieces]
  (def out @[])
  (each p pieces
    (cond
      (or (nil? p) (false? p)) nil
      (dictionary? p) (each k (sorted (keys p))
                        (when (p k) (array/push out (string k))))
      (array/push out (string p))))
  (string/join out " "))

(defn html5
  ``A full HTML5 document fragment: the doctype followed by
  [:html attrs & children]. `attrs` is optional:

      (html5 {:lang "en"} [:head ...] [:body ...])``
  [& forms]
  (def [attrs children]
    (if (dictionary? (first forms))
      [(first forms) (drop 1 forms)]
      [{} forms]))
  @[doctype [:html attrs ;children]])
