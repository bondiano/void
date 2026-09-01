### void/datastar/proto — the Datastar SSE wire format (v1), as pure
### functions (SPEC §5.5's experiment, ROADMAP wave 5, ADR-0037).
###
### Datastar reads two SSE event types: `datastar-patch-elements`
### (HTML morphed/patched into the DOM) and `datastar-patch-signals`
### (a JSON patch of the page's signals). A builder here returns the
### `{:event :data}` value that `void/http`'s ring/sse-event already
### knows how to frame — multi-line :data becomes one `data:` line per
### line, which is exactly how Datastar spells multi-line elements
### (`data: elements <div>` ...). Nothing in this module touches a
### request, a response or a template engine; ./init composes those.

(import spork/json)

(def modes
  "The element patch modes Datastar accepts."
  {:outer true :inner true :replace true :prepend true
   :append true :before true :after true :remove true})

(defn- mode-name [mode]
  (cond
    (string? mode) mode
    (if (get modes mode)
      (string mode)
      (errorf "unknown patch mode %q (known: %s)"
              mode
              (string/join (map |(string/format "%q" $) (sorted (keys modes)))
                           " ")))))

(defn- push-lines [out field value]
  (each line (string/split "\n" (string value))
    (array/push out (string field " " line))))

(defn patch-elements
  ``The `datastar-patch-elements` event: `html` is ready markup (the
  rendering side lives in ./init), morphed into the DOM by top-level
  element id unless opts say otherwise:

      (patch-elements `<div id="hal">…</div>`)
      (patch-elements `<li>…</li>` {:selector "#list" :mode :append})
      (patch-elements nil {:selector "#toast" :mode :remove})

  opts: :selector (CSS selector overriding id matching), :mode (see
  `modes`; Datastar's default is :outer), :use-view-transition. html
  may be nil only for :mode :remove with a :selector.``
  [html &opt opts]
  (default opts {})
  (def out @[])
  (when-let [s (get opts :selector)]
    (array/push out (string "selector " s)))
  (when-let [m (get opts :mode)]
    (array/push out (string "mode " (mode-name m))))
  (when (get opts :use-view-transition)
    (array/push out "useViewTransition true"))
  (if (nil? html)
    (unless (and (= "remove" (mode-name (get opts :mode :outer)))
                 (get opts :selector))
      (error "patch-elements without html is only :mode :remove with a :selector"))
    (push-lines out "elements" html))
  {:event "datastar-patch-elements"
   :data (string/join out "\n")})

(defn patch-signals
  ``The `datastar-patch-signals` event: `signals` is a dictionary
  (JSON-encoded here) or a ready JSON string; a signal set to nil in a
  dictionary is removed on the page, per the protocol. opts:
  :only-if-missing — patch a signal only when the page does not have
  it yet.``
  [signals &opt opts]
  (default opts {})
  (def out @[])
  (when (get opts :only-if-missing)
    (array/push out "onlyIfMissing true"))
  (push-lines out "signals"
              (if (dictionary? signals) (json/encode signals) signals))
  {:event "datastar-patch-signals"
   :data (string/join out "\n")})

(defn remove-elements
  "Remove the elements a CSS selector matches — patch-elements with
  :mode :remove and no markup."
  [selector]
  (patch-elements nil {:selector selector :mode :remove}))
