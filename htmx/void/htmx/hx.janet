### void/htmx/hx — hx-attribute helpers (SPEC.md §5.5, ROADMAP 1.3).
###
### Builders for htmx attributes as plain hiccup attribute tables:
### keywords become hx-* names, swap styles are written the way htmx
### spells them (:outer-html -> "outerHTML"), dictionary values
### (hx-vals, hx-headers) are JSON-encoded. Everything returns data —
### merge it into an element's attributes or splice several builders
### together with merge.

(import spork/json)

(def swap-styles
  "Swap style keywords -> htmx spelling."
  {:inner-html "innerHTML"
   :outer-html "outerHTML"
   :text-content "textContent"
   :before-begin "beforebegin"
   :after-begin "afterbegin"
   :before-end "beforeend"
   :after-end "afterend"
   :delete "delete"
   :none "none"})

(defn swap-style
  "The htmx spelling of a swap style: a known keyword is translated
  (:outer-html -> \"outerHTML\"), a string passes through — modifiers
  like \"outerHTML swap:1s\" stay verbatim."
  [style]
  (cond
    (string? style) style
    (or (get swap-styles style)
        (errorf "unknown swap style %q (known: %s)"
                style
                (string/join (map |(string/format "%q" $)
                                  (sorted (keys swap-styles)))
                             " ")))))

(def- verbs {:get true :post true :put true :patch true :delete true})

(defn- attr-value [k v]
  (cond
    (dictionary? v) (json/encode v)
    (boolean? v) (string v)
    (or (= k :swap) (= k :swap-oob)) (swap-style v)
    (string v)))

(defn attrs
  ``htmx attributes from key-value pairs:

      (hx/attrs :get "/orders" :target "#list" :swap :outer-html)
      # @{"hx-get" "/orders" "hx-target" "#list" "hx-swap" "outerHTML"}

  Keyword keys get the hx- prefix (:target -> "hx-target"); string
  keys pass through verbatim ("hx-on:click"). Values: :swap/:swap-oob
  keywords translate via swap-style, dictionaries JSON-encode
  (:vals, :headers), booleans render as "true"/"false", nil drops the
  attribute.``
  [& kvs]
  (when (odd? (length kvs))
    (error "hx/attrs expects key-value pairs"))
  (def out @{})
  (each [k v] (partition 2 kvs)
    (unless (nil? v)
      (def name
        (cond
          (string? k) k
          (keyword? k) (string "hx-" k)
          (errorf "hx attribute key must be a keyword or string, got %q" k)))
      (put out name (attr-value k v))))
  out)

(defn- verb-attrs [verb url kvs]
  (attrs verb url ;kvs))

(defn get* "hx-get plus extra attrs: (hx/get* \"/x\" :target \"#y\")."
  [url & kvs] (verb-attrs :get url kvs))
(defn post "hx-post plus extra attrs."
  [url & kvs] (verb-attrs :post url kvs))
(defn put* "hx-put plus extra attrs."
  [url & kvs] (verb-attrs :put url kvs))
(defn patch "hx-patch plus extra attrs."
  [url & kvs] (verb-attrs :patch url kvs))
(defn delete "hx-delete plus extra attrs."
  [url & kvs] (verb-attrs :delete url kvs))

(defn oob
  ``Mark a hiccup element for an out-of-band swap: adds hx-swap-oob
  (\"true\" by default, or a swap style / selector string):

      (hx/oob [:div {:id "cart-count"} 3])
      (hx/oob [:tr {:id "row-7"} ...] :outer-html)``
  [node &opt swap]
  (unless (and (tuple? node) (keyword? (first node)))
    (errorf "hx/oob expects a [tag ...] hiccup element, got %q" node))
  (def v (if (nil? swap) "true" (swap-style swap)))
  (def attrs* (get node 1))
  (if (dictionary? attrs*)
    [(first node) (merge attrs* {:hx-swap-oob v}) ;(tuple/slice node 2)]
    [(first node) {:hx-swap-oob v} ;(tuple/slice node 1)]))
