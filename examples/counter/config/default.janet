# counter — the config layer every profile shares (void/core/config:
# plugin defaults <- default.janet <- <profile>.janet <- VOID_* env
# vars <- CLI overrides).

{# The stylesheet, at both ends. `styles/app.css` is the source the
 # standalone tailwind compiler reads — no node, no npm; `void assets
 # install` downloads the binary once and `void dev` keeps it in
 # --watch. `assets/app.css` is what it writes, inside [:html :assets
 # :root] so that development serves it straight out of the tree and
 # `void assets build` fingerprints it with everything else. The markup
 # is `(html/asset "app.css")` either way.
 :html {:assets {:root "assets"
                 :out "build/assets"
                 :tailwind {:input "styles/app.css"
                            :output "assets/app.css"}}}

 :http {:static {:root "assets" :prefix "/assets/"}}}
