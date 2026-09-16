### void/html/temple — the temple view engine.
###
### spork/temple as the alternative to the hiccup pipeline, behind the
### same :void.html/engine extension point: a view is a compiled
### template function ((temple/create source) or temple's module
### loader), the render context arrives as temple's `args`. A layout
### is another template receiving the rendered view as (args :content)
### — splice it with {- (args :content) -} (already-escaped HTML must
### not be escaped twice).
###
### **Views only, and that is the decision** (wave 8, ADR-0050 §8).
### The framework's helpers — `form/field`, `form/form`, `html/pager`,
### `html/flash-view`, every `hx/` builder, the CSRF slot — answer with
### *hiccup*, and they are not reimplemented here. A template that wants
### one renders it and splices the result — `{$ ... $}` is temple's
### compile-time chunk, which is where a template does its imports:
###
###     {$ (import void/html/init :as html) $}
###     {- (html/render-string (form/field spec value errors)) -}
###
### (or the handler renders it and the template splices `(args :field)`,
### which is the same bridge one step earlier).
###
### A second, string-building set of the same helpers would be a copy of
### the first (the thing this wave exists to remove), and a worse copy:
### hiccup escapes by construction, a helper that pasted strings would
### have to escape by discipline, which is how an injection gets written.
### The bridge is one call, it is in the view layer where it belongs, and
### it costs the engine nothing.

(import spork/temple)

(def create
  "Compile a template string into a template function (spork/temple)."
  temple/create)

(defn render
  "Run a compiled template with `args`, returning the output buffer."
  [tmpl args]
  (def buf @"")
  (with-dyns [:out buf]
    (tmpl args))
  buf)

(defn engine-render
  "The :void.html/engine renderer: render the view template with the
  context as args; when the context carries a :layout template, render
  it with the view's output as :content."
  [view context]
  (def body (render view context))
  (if-let [layout (get context :layout)]
    (render layout (merge (if (dictionary? context) context {})
                          {:content body}))
    body))
