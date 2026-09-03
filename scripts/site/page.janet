### scripts/site/page — the shell every page of the docs site shares, as
### hiccup for void/html.
###
### The site is a documentation product rather than a folder of rendered
### files: a landing that says what void is in one screen, a sidebar
### carrying the whole map so a reader always knows where they are, a
### contents rail beside long documents, and a search that opens on `/`.
### The writing is still the site — the chrome stays quiet, the column
### keeps a reading measure, and the palette is the one void/dash and
### void/admin already speak (control room: dark tokens, light by
### preference), so the framework's own surfaces and its documentation are
### visibly the same system.
###
### One stylesheet and one script, both written next to the pages, no
### build step. The script is progressive: without it the search box is a
### plain form that searches the repository on GitHub, and every link on
### every page still resolves.

(import void/html/hiccup :as h)

(def nav
  ``The site map, in sidebar order: groups of [label href], hrefs
  site-root relative (`render` prefixes them for pages below the root). A
  page lights up its entry through :here, and the entry may unfold a
  :subnav of its own children — the ADRs under ADR, the packages under
  Modules.``
  [{:title "Start"
    :items [["Overview" "overview.html"]
            ["Getting started" "getting-started.html"]
            ["Idea → deploy" "idea-to-deploy.html"]
            ["Cookbook" "cookbook/index.html"]]}
   {:title "Reference"
    :items [["Modules" "modules/index.html"]
            ["Config" "config.html"]
            ["CLI" "cli.html"]
            ["Contracts" "contracts.html"]]}
   {:title "Project"
    :items [["Deploy" "deploy.html"]
            ["Benchmarks" "bench.html"]
            ["Compared" "comparison.html"]
            ["Contributing" "contributing.html"]
            ["Changelog" "changelog.html"]]}])

(def github "https://github.com/bondiano/void")

(defn entry
  "The [group label] of the nav entry with this href, or nil."
  [href]
  (var found nil)
  (each g nav
    (each [label h] (g :items)
      (when (and (nil? found) (= h href))
        (set found [(g :title) label]))))
  found)

(defn section
  ``«Group · Label» for a page's :here — the line a search result
  prints under a page hit, so a reader sees which part of the site it
  lives in before going there.``
  [here]
  (if-let [[group label] (entry here)]
    (string group " · " label)
    ""))

(defn short-name
  ``What to call a page in one or two words: its nav label when it is
  a nav entry (a document's own heading can be a sentence), and otherwise
  its own
  title — an ADR, a cookbook recipe and a package page each have a name
  already.``
  [out title]
  (if-let [[_ label] (entry out)] label (or title "void")))

(def description
  "The site-wide description meta/OG tags carry; a page may override
  it through :description."
  "void — a batteries-included web framework for Janet: Laravel/Spring-level capabilities, Lisp-idiomatic architecture, everything extensible through plugins.")

(def favicon
  "An emoji favicon as an inline SVG — no file, no extra request."
  "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🕳️</text></svg>")

(def css
  ``The whole stylesheet. One file, no build step; the dark half is
  the same tokens redefined, and the tokens are void/dash's — the
  dashboard, the admin and the docs are one design language, with the
  default scheme flipped because a document is read in daylight and an
  operator's panel is not.``
  ```
:root {
  --bg: #f7f8fa; --panel: #ffffff; --panel-2: #edf0f4;
  --line: #dbe0e7; --line-soft: #e7ebf0;
  --fg: #1d242c; --muted: #5d6b7a;
  --accent: #0b6fb0; --accent-soft: rgba(11, 111, 176, .1);
  --mark: #2e7d5b;
  --shadow: 0 8px 28px rgba(29, 36, 44, .12);
  --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --bar-h: 3.05rem;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #101418; --panel: #171c22; --panel-2: #1d242c;
    --line: #2a323c; --line-soft: #232b34;
    --fg: #dde4ec; --muted: #93a2b3;
    --accent: #4cc2ff; --accent-soft: rgba(76, 194, 255, .12);
    --mark: #6dbd96;
    --shadow: 0 8px 28px rgba(0, 0, 0, .5);
    color-scheme: dark;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; scrollbar-color: var(--line)
transparent; } body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 16px/1.65 var(--sans); -webkit-font-smoothing: antialiased;
}
::selection { background: var(--accent-soft); color: inherit; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px;
border-radius: 3px; } a { color: var(--accent); text-decoration-thickness:
1px; text-underline-offset: 2px; } /* the sidebar carries up to sixty
links; a keyboard reader gets past
   them in one tab */
.skip {
  position: absolute; left: -9999px; top: .4rem; z-index: 40;
  background: var(--panel); border: 1px solid var(--accent); border-radius: 7px;
  padding: .45rem .8rem; font-size: .85rem; text-decoration: none;
}
.skip:focus { left: 1.25rem; }

/* -- top bar ---------------------------------------------------------- */

header.top {
  position: sticky; top: 0; z-index: 20; height: var(--bar-h);
  display: flex; align-items: center;
  background: var(--panel); border-bottom: 1px solid var(--line);
}
header.top .row {
  width: 100%; max-width: 92rem; margin: 0 auto;
  padding: 0 1.25rem; display: flex; align-items: center; gap: 1rem;
}
.wordmark {
  font: 700 1.05rem/1 var(--mono); color: var(--fg);
  text-decoration: none; letter-spacing: .02em; white-space: nowrap;
} .wordmark::before { content: "("; color: var(--accent); }
.wordmark::after { content: ")"; color: var(--accent); } .top .tagline {
  color: var(--muted); font-size: .82rem; white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis;
} .top .gh {
  margin-left: auto; color: var(--muted); font-size: .85rem; text-decoration: none;
  white-space: nowrap;
} .top .gh:hover { color: var(--fg); } @media (max-width: 46rem) { .top
.tagline { display: none; } }

/* -- search ----------------------------------------------------------- */

form.search { position: relative; margin-left: auto; width: min(22rem,
42vw); } form.search input {
  width: 100%; font: .85rem/1 var(--sans); color: var(--fg);
  background: var(--bg); border: 1px solid var(--line); border-radius: 7px;
  padding: .45rem .6rem;
} form.search input::placeholder { color: var(--muted); } form.search
input::-webkit-search-cancel-button { display: none; } .results {
  position: absolute; top: calc(100% + .4rem); right: 0;
  width: min(34rem, 88vw); max-height: min(28rem, 70vh); overflow-y: auto;
  background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
  box-shadow: var(--shadow); padding: .3rem; z-index: 30;
} .results a {
  display: block; padding: .4rem .55rem; border-radius: 6px;
  text-decoration: none; color: var(--fg);
} .results a:hover, .results a.sel { background: var(--accent-soft); }
.results .r-title { font-size: .9rem; font-weight: 600; } .results
.r-where {
  font-size: .75rem; color: var(--muted); font-family: var(--mono);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
} .results .r-none { padding: .5rem .55rem; color: var(--muted);
font-size: .85rem; } .results mark { background: none; color:
var(--accent); font-weight: 700; }
[hidden] { display: none !important; }

/* -- the three columns ------------------------------------------------ */

.shell {
  max-width: 92rem; margin: 0 auto; padding: 0 1.25rem;
  display: grid; grid-template-columns: 14.5rem minmax(0, 1fr); gap: 2rem;
  align-items: start;
} @media (min-width: 86rem) {
  .shell { grid-template-columns: 14.5rem minmax(0, 1fr) 14rem; }
} main { padding: 1.4rem 0 5rem; max-width: 52rem; min-width: 0; }

/* -- sidebar ---------------------------------------------------------- */

nav.side {
  position: sticky; top: var(--bar-h); align-self: start;
  max-height: calc(100vh - var(--bar-h)); overflow-y: auto;
  overscroll-behavior: contain; padding: 1.4rem .5rem 3rem 0;
  font-size: .87rem; border-right: 1px solid var(--line-soft);
} .side-group + .side-group { margin-top: 1.3rem; } .side-title {
  font: 600 .7rem/1 var(--sans); letter-spacing: .08em; text-transform: uppercase;
  color: var(--muted); margin-bottom: .45rem; padding-left: .55rem;
} nav.side ul { list-style: none; margin: 0; padding: 0; } nav.side a {
  display: block; padding: .22rem .55rem; border-radius: 6px;
  color: var(--muted); text-decoration: none; line-height: 1.45;
} nav.side a:hover { color: var(--fg); background: var(--panel-2); }
nav.side a.here { color: var(--fg); background: var(--accent-soft);
font-weight: 600; } ul.side-sub {
  margin: .15rem 0 .5rem .55rem; padding-left: .6rem;
  border-left: 1px solid var(--line);
} ul.side-sub a { font-size: .82rem; padding: .15rem .5rem; } ul.side-sub
a.here { background: none; color: var(--accent); }

@media (max-width: 60rem) {
  .shell { grid-template-columns: minmax(0, 1fr); gap: 0; }
  nav.side {
    position: static; max-height: none; overflow: visible;
    border: 1px solid var(--line); border-radius: 10px;
    padding: .8rem .9rem; margin: 1rem 0 .5rem; background: var(--panel);
    display: grid; grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr));
    gap: .6rem 1rem; font-size: .84rem;
  }
  .side-group + .side-group { margin-top: 0; }
  .side-title { margin-bottom: .2rem; }
  nav.side a { padding: .1rem .4rem; }
  ul.side-sub { display: none; }
}

/* -- contents rail ---------------------------------------------------- */

nav.toc {
  position: sticky; top: var(--bar-h); align-self: start;
  max-height: calc(100vh - var(--bar-h)); overflow-y: auto;
  overscroll-behavior: contain; padding: 1.6rem 0 3rem;
  font-size: .8rem; line-height: 1.45;
} @media (max-width: 86rem) { nav.toc { display: none; } } nav.toc
.toc-title {
  font-weight: 600; color: var(--muted); text-transform: uppercase;
  font-size: .7rem; letter-spacing: .08em; margin-bottom: .5rem;
} nav.toc ol { list-style: none; margin: 0; padding: 0; } nav.toc li {
margin: .28rem 0; } nav.toc li.toc-h3 { padding-left: .9rem; } nav.toc a {
color: var(--muted); text-decoration: none; display: block; } nav.toc
a:hover { color: var(--accent); }

/* -- prose ------------------------------------------------------------ */

h1, h2, h3, h4 { line-height: 1.25; scroll-margin-top: calc(var(--bar-h) +
1rem); } h1 { font-size: 1.8rem; margin: .8rem 0 .9rem; letter-spacing:
-.01em; } h2 {
  font-size: 1.32rem; margin: 2.4rem 0 .7rem;
  border-bottom: 1px solid var(--line); padding-bottom: .3rem;
} h3 { font-size: 1.08rem; margin: 1.9rem 0 .5rem; } h4 { font-size: 1rem;
margin: 1.4rem 0 .4rem; } p, li { overflow-wrap: break-word; } code {
  font: .86em var(--mono); background: var(--panel-2);
  border-radius: 4px; padding: .1em .3em;
}
pre {
  background: var(--panel-2); border: 1px solid var(--line-soft); border-radius: 9px;
  padding: .9rem 1rem; overflow-x: auto; line-height: 1.5;
}
pre code { background: none; padding: 0; font-size: .85rem; }
blockquote {
  margin: 1rem 0; padding: .1rem 1rem; color: var(--muted);
  border-left: 3px solid var(--accent); background: var(--panel-2);
  border-radius: 0 7px 7px 0;
}
hr { border: none; border-top: 1px solid var(--line); margin: 2.5rem 0; }
.table-wrap { overflow-x: auto; margin: 1rem 0; }
table { border-collapse: collapse; font-size: .92rem; min-width: 100%; }
th, td {
  border: 1px solid var(--line); padding: .45rem .65rem;
  text-align: left; vertical-align: top;
} th { background: var(--panel-2); } .task {
  display: inline-block; width: 1.05em; height: 1.05em; line-height: 1.05em;
  margin-right: .35em; border: 1px solid var(--muted); border-radius: 3px;
  font-size: .8em; text-align: center; vertical-align: .05em; color: transparent;
}
.task.done { color: var(--mark); border-color: var(--mark); font-weight: 700; }
dl.ref dt { margin-top: 1.6rem; font-weight: 600; }
dl.ref dd { margin: .3rem 0 0 0; }
.tag {
  display: inline-block; font: 600 .72rem/1.5 var(--sans); border-radius: 4px;
  padding: .05rem .4rem; margin-left: .5rem; vertical-align: .12em;
  background: var(--panel-2); color: var(--muted); border: 1px solid var(--line);
}
.tag.ro { color: var(--mark); border-color: var(--mark); }
.muted { color: var(--muted); }
a.anchor {
  margin-left: .4rem; font-size: .78em; text-decoration: none;
  color: var(--muted); opacity: 0;
}
h2:hover > a.anchor, h3:hover > a.anchor,
h4:hover > a.anchor, a.anchor:focus-visible { opacity: 1; }
pre .tok-comment { color: var(--muted); }
pre .tok-str { color: var(--mark); }
pre .tok-kw { color: var(--accent); }
pre .tok-head { color: var(--accent); font-weight: 600; }

/* -- landing ---------------------------------------------------------- */

main.landing { max-width: 62rem; margin: 0 auto; padding: 3rem 1.25rem
5rem; } .hero { text-align: center; } .hero h1 {
  font: 700 clamp(2.4rem, 7vw, 3.6rem)/1 var(--mono);
  margin: 0; letter-spacing: -.02em;
} .hero h1::before { content: "("; color: var(--accent); } .hero h1::after
{ content: ")"; color: var(--accent); } .hero .lede {
  font-size: 1.15rem; color: var(--muted); max-width: 40rem;
  margin: 1rem auto 0; line-height: 1.55;
} .hero .claim { font-size: 1rem; max-width: 44rem; margin: 1.2rem auto 0;
} .cta { display: flex; gap: .7rem; justify-content: center; flex-wrap:
wrap; margin: 1.8rem 0 0; } .cta a {
  display: inline-block; padding: .55rem 1.1rem; border-radius: 8px;
  text-decoration: none; font-size: .92rem; font-weight: 600;
  border: 1px solid var(--line);
} .cta a.primary { background: var(--accent); border-color: var(--accent);
color: var(--panel); } .cta a.primary:hover { filter: brightness(1.08); }
.cta a.ghost { color: var(--fg); background: var(--panel); } .cta
a.ghost:hover { border-color: var(--accent); color: var(--accent); }

.strip {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(7rem, 1fr));
  gap: 1px; background: var(--line-soft);
  border: 1px solid var(--line); border-radius: 10px; overflow: hidden;
  margin: 3rem 0 1rem;
} .strip div { background: var(--panel); padding: .9rem 1rem; } .strip .n
{ font: 700 1.5rem/1.1 var(--mono); color: var(--fg); } .strip .k {
  font-size: .72rem; letter-spacing: .07em; text-transform: uppercase;
  color: var(--muted); margin-top: .25rem;
}

@media (max-width: 40rem) {
  /* three columns leave the fourth number alone in a row of its own */
  .strip { grid-template-columns: repeat(2, 1fr); }
  .strip div { padding: .7rem .8rem; }
  .strip .n { font-size: 1.35rem; }
} .landing h2 {
  font-size: 1.05rem; letter-spacing: .07em; text-transform: uppercase;
  color: var(--muted); border: none; margin: 3rem 0 1rem; padding: 0;
} .landing pre { margin: 0; } .landing .prose { max-width: 46rem; }
.landing .prose p { margin: 0 0 .9rem; } .cards { display: grid;
grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); gap: .9rem; }
.card {
  display: block; text-decoration: none; color: inherit; background: var(--panel);
  border: 1px solid var(--line); border-radius: 10px; padding: .9rem 1rem;
} .card:hover { border-color: var(--accent); } .card .t { font-weight:
650; font-size: .95rem; } .card .d { color: var(--muted); font-size:
.84rem; margin-top: .25rem; line-height: 1.45; }

/* -- footer ----------------------------------------------------------- */

footer {
  max-width: 92rem; margin: 0 auto;
  padding: 1.4rem 1.25rem 3rem; border-top: 1px solid var(--line);
  color: var(--muted); font-size: .82rem;
}
  ```)

(defn- side-links
  "One sidebar group's links, with the active entry's children unfolded
  under it."
  [up here self subnav group]
  (seq [[label href] :in (get group :items)]
    [:li
     [:a {:href (string up href)
          :class (when (= href here) "here")
          :aria-current (when (= href self) "page")}
      label]
     (when (and (= href here) subnav (not (empty? subnav)))
       [:ul {:class "side-sub"}
        ;(seq [[l h] :in subnav]
           [:li [:a {:href (string up h)
                     :class (when (= h self) "here")
                     :aria-current (when (= h self) "page")}
                 l]])])]))

(defn- sidebar [up here self subnav]
  [:nav {:class "side" :aria-label "Sections"}
   ;(seq [g :in nav]
      [:div {:class "side-group"}
       [:div {:class "side-title"} (g :title)]
       [:ul ;(side-links up here self subnav g)]])])

(defn- topbar [up]
  [:header {:class "top"}
   [:div {:class "row"}
    [:a {:class "wordmark" :href (string up "index.html")} "void"]
    [:span {:class "tagline"} "everything Janet keeps, one import away"]
    [:form {:class "search" :role "search" :method "get"
            :action (string github "/search")}
     [:input {:type "search" :name "q" :id "q" :autocomplete "off"
              :spellcheck "false" :aria-label "Search the documentation"
              :placeholder "Search the docs…"}]
     [:div {:class "results" :id "results" :hidden true}]]
    [:a {:class "gh" :href github} "GitHub ↗"]]])

(defn render
  ``One page as an HTML string.

 (render {:title "" :here "spec.html" :self "spec.html" :depth 0 :body [...] :toc [...]})

  `depth` is how many directories below the site root the page lives
  (adr/ pages pass 1), so the shell, the stylesheet and the script
  resolve with relative links and the site works from any prefix —
  file://, a project page, a mirror. `here` is the nav entry the page
  lights up and `self` its own path, so a child page also marks itself
  in the unfolded `subnav`. `lang` is the document's language ("en" when absent — and the ADRs pass "ru"); `description` overrides
  the site-wide meta/OG description; `layout` :landing drops the
  sidebar and the rail for the one page that is not a document.``
  [{:title title :here here :self self :depth depth :body body :toc toc
    :generated generated :lang lang :description desc :subnav subnav
    :layout layout}]
  (default depth 0)
  (default lang "en")
  (default desc description)
  (def up (string/repeat "../" depth))
  (def full-title (if (or (nil? title) (= "void" title))
                    "void — a web framework for Janet"
                    (string title " · void")))
  (h/render-string
    (h/html5
      {:lang lang}
      [:head
       [:meta {:charset "utf-8"}]
       [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
       [:title full-title]
       [:meta {:name "description" :content desc}]
       [:meta {:property "og:type" :content "website"}]
       [:meta {:property "og:site_name" :content "void"}]
       [:meta {:property "og:title" :content full-title}]
       [:meta {:property "og:description" :content desc}]
       [:link {:rel "icon" :href favicon}]
       [:link {:rel "stylesheet" :href (string up "style.css")}]]
      [:body
       [:a {:class "skip" :href "#content"} "Skip to content"]
       (topbar up)
       (if (= layout :landing)
         [:main {:class "landing" :id "content"} ;body]
         [:div {:class "shell"}
          (sidebar up here self subnav)
          [:main {:id "content"} ;body]
          (or toc [:nav {:class "toc"}])])
       [:footer
        (or generated "")
        (unless (nil? generated) " · ")
        "void is built in the open — "
        [:a {:href github} "bondiano/void"]
        " · docs generated by "
        [:code "scripts/gen-site.janet"]]
       [:script {:src (string up "site.js") :defer true}]])))
