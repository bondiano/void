### void/html/temple — the temple view engine (SPEC.md §5.4).
###
### spork/temple as the alternative to the hiccup pipeline, behind the
### same :void.html/engine extension point: a view is a compiled
### template function ((temple/create source) or temple's module
### loader), the render context arrives as temple's `args`. A layout
### is another template receiving the rendered view as (args :content)
### — splice it with {- (args :content) -} (already-escaped HTML must
### not be escaped twice).

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
