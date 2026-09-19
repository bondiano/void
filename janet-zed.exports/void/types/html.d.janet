# Types of void/html's values, named where they recur.

# A lazy view response: what `html/page` and `html/fragment` answer — the content, layout and
# context the render middleware finishes into a body.
(def HtmlView :typedef
  '@{:status :number :headers @{:string :string} :void.html/content :any
    :void.html/layout :any :void.html/context {:any :any} & r})
