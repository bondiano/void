### scripts/site/page — the one layout every page of the docs site
### shares, as hiccup for void/html.
###
### The site is deliberately chrome-light: a top bar with the section
### links, one readable column, and typography that leaves the writing
### alone — the documents are the site, the layout is not. Styling is
### a single stylesheet written next to the pages; system fonts, a
### dark scheme that follows the reader's, and no script anywhere.

(import void/html/hiccup :as h)

(def nav
  "The sections, in bar order: [label href]. hrefs are site-root
  relative; `render` prefixes them for pages below the root."
  [["Guide" "index.html"]
   ["SPEC" "spec.html"]
   ["ROADMAP" "roadmap.html"]
   ["Contracts" "contracts.html"]
   ["Config" "config.html"]
   ["CLI" "cli.html"]
   ["ADR" "adr/index.html"]
   ["Deploy" "deploy.html"]
   ["Bench" "bench.html"]])

(def github "https://github.com/bondiano/void")

(def css
  ``The whole stylesheet. One file, no build step, and the dark half
  is the same tokens redefined — the scheme is the reader's, not
  ours.``
  ```
:root {
  --bg: #fdfdfc; --fg: #1a1c1e; --muted: #5c636b; --line: #e4e2dd;
  --accent: #7150ba; --code-bg: #f3f1ec; --nav-bg: rgba(253, 253, 252, .92);
  --mark: #2e7d5b;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181c; --fg: #d8dade; --muted: #9aa1ab; --line: #2b2f36;
    --accent: #a68be0; --code-bg: #1f2126; --nav-bg: rgba(22, 24, 28, .92);
    --mark: #6dbd96;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.65 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
}
nav {
  position: sticky; top: 0; z-index: 10; backdrop-filter: blur(6px);
  background: var(--nav-bg); border-bottom: 1px solid var(--line);
}
nav .row {
  max-width: 52rem; margin: 0 auto; padding: .55rem 1.25rem;
  display: flex; align-items: baseline; gap: 1rem; flex-wrap: wrap;
}
nav .wordmark {
  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  font-weight: 700; font-size: 1.05rem; color: var(--fg);
  text-decoration: none; letter-spacing: .02em;
}
nav .wordmark::before { content: "("; color: var(--accent); }
nav .wordmark::after { content: ")"; color: var(--accent); }
nav a { color: var(--muted); text-decoration: none; font-size: .88rem; }
nav a:hover { color: var(--fg); }
nav a.here { color: var(--accent); font-weight: 600; }
nav .gh { margin-left: auto; }
main { max-width: 52rem; margin: 0 auto; padding: 2rem 1.25rem 5rem; }
h1, h2, h3, h4 { line-height: 1.25; scroll-margin-top: 4rem; }
h1 { font-size: 1.7rem; margin: 1.2rem 0 .8rem; }
h2 { font-size: 1.3rem; margin: 2.2rem 0 .6rem; border-bottom: 1px solid var(--line); padding-bottom: .3rem; }
h3 { font-size: 1.08rem; margin: 1.8rem 0 .5rem; }
h4 { font-size: 1rem; margin: 1.4rem 0 .4rem; }
a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
p, li { overflow-wrap: break-word; }
code {
  font: .86em ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  background: var(--code-bg); border-radius: 4px; padding: .1em .3em;
}
pre {
  background: var(--code-bg); border: 1px solid var(--line); border-radius: 8px;
  padding: .9rem 1rem; overflow-x: auto; line-height: 1.5;
}
pre code { background: none; padding: 0; font-size: .85rem; }
blockquote {
  margin: 1rem 0; padding: .1rem 1rem; color: var(--muted);
  border-left: 3px solid var(--accent); background: var(--code-bg);
  border-radius: 0 6px 6px 0;
}
hr { border: none; border-top: 1px solid var(--line); margin: 2.5rem 0; }
.table-wrap { overflow-x: auto; margin: 1rem 0; }
table { border-collapse: collapse; font-size: .92rem; min-width: 100%; }
th, td { border: 1px solid var(--line); padding: .45rem .65rem; text-align: left; vertical-align: top; }
th { background: var(--code-bg); }
.task {
  display: inline-block; width: 1.05em; height: 1.05em; line-height: 1.05em;
  margin-right: .35em; border: 1px solid var(--muted); border-radius: 3px;
  font-size: .8em; text-align: center; vertical-align: .05em; color: transparent;
}
.task.done { color: var(--mark); border-color: var(--mark); font-weight: 700; }
.crumbs { color: var(--muted); font-size: .85rem; margin-bottom: .4rem; }
.crumbs a { color: var(--muted); }
dl.ref dt { margin-top: 1.6rem; font-weight: 600; }
dl.ref dd { margin: .3rem 0 0 0; }
.tag {
  display: inline-block; font-size: .72rem; font-weight: 600; border-radius: 4px;
  padding: .05rem .4rem; margin-left: .5rem; vertical-align: .12em;
  background: var(--code-bg); color: var(--muted); border: 1px solid var(--line);
}
.tag.ro { color: var(--mark); border-color: var(--mark); }
.muted { color: var(--muted); }
footer {
  max-width: 52rem; margin: 0 auto; padding: 1.5rem 1.25rem 3rem;
  border-top: 1px solid var(--line); color: var(--muted); font-size: .82rem;
}
  ```)

(defn render
  ``One page as an HTML string.

      (render {:title "SPEC" :here "spec.html" :depth 0 :body [...]})

  `depth` is how many directories below the site root the page lives
  (adr/ pages pass 1), so the shared nav and stylesheet resolve with
  relative links and the site works from any prefix — file://, a
  project page, a mirror.``
  [{:title title :here here :depth depth :body body :generated generated}]
  (default depth 0)
  (def up (string/repeat "../" depth))
  (h/render-string
    (h/html5
      {:lang "en"}
      [:head
        [:meta {:charset "utf-8"}]
        [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
        [:title (if (or (nil? title) (= "void" title))
                  "void"
                  (string title " · void"))]
        [:link {:rel "stylesheet" :href (string up "style.css")}]]
       [:body
        [:nav
         [:div {:class "row"}
          [:a {:class "wordmark" :href (string up "index.html")} "void"]
          ;(seq [[label href] :in nav]
             [:a {:href (string up href)
                  :class (when (= href here) "here")}
              label])
          [:a {:class "gh" :href github} "GitHub"]]]
        [:main ;body]
        [:footer
         (or generated "")
         (unless (nil? generated) " · ")
         "void is built in the open — "
         [:a {:href github} "bondiano/void"]
         " · docs generated by "
         [:code "scripts/gen-site.janet"]]])))
