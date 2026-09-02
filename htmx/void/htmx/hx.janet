### void/htmx/hx — hx-attribute helpers (SPEC.md §5.5, ADR-0041).
###
### Builders for htmx attributes as plain hiccup attribute tables:
### keywords become hx-* names, swap styles are written the way htmx
### spells them (:outer-html -> "outerHTML"), dictionary values
### (hx-vals, hx-headers, hx-config) are JSON-encoded — htmx 4 reads
### its config language HCON, and a leading `{` puts HCON in JSON mode,
### so one encoder covers every dictionary-valued attribute.
###
### htmx 4 spells two things with a colon suffix on the attribute name,
### and both are keys here: inheritance is explicit
### (`hx-confirm:inherited`, ./inherited) and per-status handling hangs
### off the code (`hx-status:422`, ./status). A Janet keyword may carry
### a colon, so `(hx/attrs :confirm:inherited "sure?")` also works —
### the helpers exist to make the suffix visible in the call.
###
### Everything returns data — merge it into an element's attributes or
### splice several builders together with merge.

(import spork/json)

(def swap-styles
  ``Swap style keywords -> htmx spelling. The four morph styles are
  htmx 4's: `innerMorph`/`outerMorph` diff the DOM in place (focus,
  scroll and form state survive), `outerSync` morphs the target's
  attributes and then replaces its children, `upsert` matches by id.
  The position aliases (:before/:after/:prepend/:append) resolve to
  the canonical insert-adjacent spelling.``
  {:inner-html "innerHTML"
   :outer-html "outerHTML"
   :text-content "textContent"
   :inner-morph "innerMorph"
   :outer-morph "outerMorph"
   :outer-sync "outerSync"
   :upsert "upsert"
   :before-begin "beforebegin"
   :after-begin "afterbegin"
   :before-end "beforeend"
   :after-end "afterend"
   :before "beforebegin"
   :prepend "afterbegin"
   :append "beforeend"
   :after "afterend"
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

(defn- base-key
  "The attribute name before its htmx 4 suffix: :swap:inherited -> :swap."
  [k]
  (if-let [i (string/find ":" k)]
    (keyword (string/slice k 0 i))
    k))

(defn- attr-value [k v]
  (def base (base-key k))
  (cond
    (dictionary? v) (json/encode v)
    (boolean? v) (string v)
    (or (= base :swap) (= base :swap-oob)) (swap-style v)
    (string v)))

(defn attrs
  ``htmx attributes from key-value pairs:

      (hx/attrs :get "/orders" :target "#list" :swap :outer-html)
      # @{"hx-get" "/orders" "hx-target" "#list" "hx-swap" "outerHTML"}

  Keyword keys get the hx- prefix (:target -> "hx-target"); string
  keys pass through verbatim ("hx-on:click"). Values: :swap/:swap-oob
  keywords translate via swap-style, dictionaries JSON-encode
  (:vals, :headers, :config), booleans render as "true"/"false", nil
  drops the attribute.``
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

(defn inherited
  ``The same attributes, marked to reach descendants. htmx 4 does not
  inherit implicitly: an attribute applies to the element it sits on
  unless its name carries the `:inherited` suffix.

      (hx/inherited :confirm "Are you sure?" :target "#main")
      # @{"hx-confirm:inherited" "Are you sure?"
      #   "hx-target:inherited" "#main"}

  Values follow hx/attrs; the suffix lands on every key the call
  produces, so keep an element's own attributes in a separate call.``
  [& kvs]
  (tabseq [[name v] :pairs (attrs ;kvs)]
    (string name ":inherited") v))

(defn status
  ``Per-status-code handling (htmx 4 `hx-status:CODE`): a response with
  that status is swapped the way the spec says instead of the way the
  element otherwise would. The code is exact (422) or a wildcard
  ("42x", "4xx"); the spec is a dictionary — :swap translates like any
  swap style — or a verbatim HCON string:

      (hx/status 422 {:swap :inner-html :target "#errors"})
      # @{"hx-status:422" "{\"swap\":\"innerHTML\",\"target\":\"#errors\"}"}
      (hx/status :5xx "swap:none")

  htmx 4 swaps every response but 204 and 304, so this is where a
  validation error chooses its own target instead of riding the
  happy path's.``
  [code spec]
  (def value
    (if (dictionary? spec)
      (json/encode (if-let [s (get spec :swap)]
                     (merge spec {:swap (swap-style s)})
                     spec))
      (string spec)))
  @{(string "hx-status:" code) value})

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
(defn query
  ``hx-query plus extra attrs — htmx 4's QUERY verb: a read that sends
  its parameters in the body instead of the URL, for filters too long
  or too private for a query string.``
  [url & kvs] (verb-attrs :query url kvs))

(defn oob
  ``Mark a hiccup element for an out-of-band swap: adds hx-swap-oob
  (\"true\" by default, or a swap style / selector string):

      (hx/oob [:div {:id "cart-count"} 3])
      (hx/oob [:tr {:id "row-7"} ...] :outer-html)

  htmx 4 swaps out-of-band elements *after* the main content, in
  document order, and matches them by id alone — for content that
  needs its own target or swap style, reach for hx/partial.``
  [node &opt swap]
  (unless (and (tuple? node) (keyword? (first node)))
    (errorf "hx/oob expects a [tag ...] hiccup element, got %q" node))
  (def v (if (nil? swap) "true" (swap-style swap)))
  (def attrs* (get node 1))
  (if (dictionary? attrs*)
    [(first node) (merge attrs* {:hx-swap-oob v}) ;(tuple/slice node 2)]
    [(first node) {:hx-swap-oob v} ;(tuple/slice node 1)]))

(defn partial
  ``An `<hx-partial>` element — htmx 4's out-of-band swap with the full
  swapping vocabulary instead of an id match. The wrapper is not part
  of the document: htmx reads its target and swap style, swaps the
  children in and drops the tag.

      (hx/partial "#cart-count" 3)
      (hx/partial {:target "#messages" :swap :before-end}
                  [:li "new message"])

  A string is the target selector; a dictionary carries :target and
  an optional :swap (default innerHTML). Partials swap after the main
  content, and a response made of partials alone performs no main
  swap at all — which is how one handler answers several regions
  without a target for the response itself.``
  [spec & children]
  (def opts (if (dictionary? spec) spec {:target spec}))
  (def target (get opts :target))
  (unless (string? target)
    (errorf "hx/partial needs a target selector, got %q" target))
  (def swap (get opts :swap))
  [:hx-partial
   (if (nil? swap)
     {:hx-target target}
     {:hx-target target :hx-swap (swap-style swap)})
   ;children])
