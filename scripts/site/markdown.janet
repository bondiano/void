### scripts/site/markdown — the subset of Markdown this repository's
### documents actually use, parsed into void/html hiccup.
###
### Not CommonMark, on purpose: the corpus is docs/*.md, docs/adr/*.md,
### README.md and CONTRIBUTING.md, and the constructs below are the
### constructs they contain — ATX headers, paragraphs, fenced code,
### pipe tables, nested bullet/ordered lists with task checkboxes,
### blockquotes, horizontal rules, and the inline four (code, strong,
### emphasis, links). Anything else in a future document will render
### as visible text rather than silently vanish, which is the failure
### direction a generator wants.
###
### The output is hiccup for void/html — the site is rendered by the
### same engine an application's pages are, which is the dogfooding
### this repository runs on. Text nodes are plain strings, and the
### hiccup renderer escapes them; nothing here builds HTML by string
### concatenation.
###
### `parse` takes an optional link-rewriter, because the corpus links
### documents to each other by their .md names and the site knows
### where each of those lives as a page.

# -- inline spans --------------------------------------------------------

(defn- find-run
  "End index of the backtick run starting at i."
  [s i]
  (var j i)
  (while (and (< j (length s)) (= 96 (s j))) (++ j))
  j)

(defn- find-close
  "Index of the next backtick run of exactly `n` at or after i, or nil."
  [s i n]
  (var at i)
  (var found nil)
  (while (and (nil? found) (< at (length s)))
    (if (= 96 (s at))
      (let [end (find-run s at)]
        (if (= n (- end at))
          (set found at)
          (set at end)))
      (++ at)))
  found)

(var- inline nil) # forward declaration: emphasis recurses

(defn- try-code
  "A `code span` at i, as [node next-i], or nil."
  [s i]
  (when (= 96 (s i))
    (def open-end (find-run s i))
    (def n (- open-end i))
    (when-let [close (find-close s open-end n)]
      [[:code (string/slice s open-end close)] (+ close n)])))

(defn- try-strong
  "**strong** at i, as [node next-i], or nil."
  [s i]
  (when (and (= 42 (s i)) (= 42 (get s (inc i))))
    (when-let [close (string/find "**" s (+ i 2))]
      (when (> close (+ i 2))
        [[:strong ;(inline (string/slice s (+ i 2) close))] (+ close 2)]))))

(defn- try-em
  "*emphasis* at i, as [node next-i], or nil. A lone asterisk followed
  by whitespace is a character, not markup."
  [s i]
  (when (and (= 42 (s i))
             (not= 32 (get s (inc i)))
             (not (nil? (get s (inc i)))))
    (var close nil)
    (var at (inc i))
    (while (and (nil? close) (< at (length s)))
      (if (and (= 42 (s at)) (not= 32 (get s (dec at))))
        (set close at)
        (++ at)))
    (when (and close (> close (inc i)))
      [[:em ;(inline (string/slice s (inc i) close))] (inc close)])))

(defn- try-link
  "[text](url) at i, as [node next-i], or nil. The url is left for the
  caller's rewriter; nested brackets are not in the corpus."
  [s i]
  (when (= 91 (s i))                                    # [
    (when-let [close-text (string/find "]" s i)]
      (when (= 40 (get s (inc close-text)))             # (
        (when-let [close-url (string/find ")" s close-text)]
          [[:a {:href (string/slice s (+ close-text 2) close-url)}
            ;(inline (string/slice s (inc i) close-text))]
           (inc close-url)])))))

(def- specials
  "Bytes that can open an inline construct."
  {96 try-code 42 nil 91 try-link})   # ` * [

(varfn inline
  ``One line of prose as an array of hiccup nodes: strings (escaped by
  the renderer) interleaved with :code/:strong/:em/:a elements.``
  [s]
  (def out @[])
  (def plain (buffer))
  (defn flush! []
    (unless (empty? plain)
      (array/push out (string plain))
      (buffer/clear plain)))
  (var i 0)
  (while (< i (length s))
    (def c (s i))
    (def hit
      (cond
        (= c 96) (try-code s i)
        (= c 42) (or (try-strong s i) (try-em s i))
        (= c 91) (try-link s i)
        nil))
    (if hit
      (do (flush!)
          (array/push out (hit 0))
          (set i (hit 1)))
      (do (buffer/push-byte plain c)
          (++ i))))
  (flush!)
  out)

(defn- rewrite-links
  "Apply the link rewriter to every :a in an inline tree."
  [nodes rewrite]
  (if (nil? rewrite)
    nodes
    (seq [n :in nodes]
      (if (and (indexed? n) (= :a (first n)))
        [:a {:href (rewrite (get-in n [1 :href]))} ;(rewrite-links (array/slice n 2) rewrite)]
        n))))

# -- slugs ---------------------------------------------------------------

(defn slug
  ``A header's anchor id, the way GitHub spells it closely enough for
  the corpus's own #links: lowercased ASCII, everything that is not a
  letter, digit or hyphen dropped, spaces to hyphens. Non-ASCII bytes
  (the Russian headers) pass through untouched — case-sensitive, and
  consistently so on both ends because both ends are this function.``
  [text]
  (def b (buffer))
  (each c text
    (cond
      (and (>= c 65) (<= c 90)) (buffer/push-byte b (+ c 32))
      (or (and (>= c 97) (<= c 122)) (and (>= c 48) (<= c 57)) (= c 45)) (buffer/push-byte b c)
      (= c 32) (buffer/push-byte b 45)
      (>= c 128) (buffer/push-byte b c)))
  (string b))

(defn- strip-markup
  "Inline nodes as their visible text, for slugs."
  [nodes]
  (string/join
    (seq [n :in nodes]
      (if (indexed? n)
        (strip-markup (filter |(not (dictionary? $)) (array/slice n 1)))
        (string n)))
    ""))

# -- block structure -----------------------------------------------------

(def- fence-peg (peg/compile ~(* "```" (capture (any (if-not "\n" 1))) -1)))
(def- header-peg (peg/compile ~(* (capture (between 1 6 "#")) " " (capture (any 1)))))
(def- hr-peg (peg/compile ~(* (at-least 3 "-") -1)))
(def- table-sep-peg (peg/compile ~(* (any (set "|-: ")) "-" (any (set "|-: ")) -1)))
(def- item-peg
  # indent, marker (bullet or "1."), text
  (peg/compile ~(* (capture (any " "))
                   (capture (+ (set "-*") (* (some (range "09")) ".")))
                   " " (capture (any 1)))))

(defn- table-cells [line]
  (def trimmed (string/trim (string/trim line) "|"))
  (map string/trim (string/split "|" trimmed)))

(var- blocks nil) # forward declaration: blockquotes and list items recurse

(defn- parse-table [lines i rewrite]
  (def head (table-cells (lines i)))
  (var j (+ i 2))
  (def rows @[])
  (while (and (< j (length lines)) (string/has-prefix? "|" (string/trim (lines j))))
    (array/push rows (table-cells (lines j)))
    (++ j))
  [[:div {:class "table-wrap"}
    [:table
     [:thead [:tr ;(map |[:th ;(rewrite-links (inline $) rewrite)] head)]]
     [:tbody ;(seq [row :in rows]
                [:tr ;(map |[:td ;(rewrite-links (inline $) rewrite)] row)])]]]
   j])

(defn- checkbox
  "A task-list item's [x]/[ ] prefix as a marker span, or nil."
  [text]
  (cond
    (string/has-prefix? "[x] " text) [[:span {:class "task done"} "✓"] (string/slice text 4)]
    (string/has-prefix? "[ ] " text) [[:span {:class "task"} ""] (string/slice text 4)]
    nil))

(defn- parse-list [lines i rewrite]
  (def m (peg/match item-peg (lines i)))
  (def indent (length (m 0)))
  (def ordered (not (index-of (m 1) ["-" "*"])))
  (def items @[])
  (var j i)
  (while (< j (length lines))
    (def line (lines j))
    (def hit (peg/match item-peg line))
    (cond
      # a deeper marker: a child list inside the current item
      (and hit (> (length (hit 0)) indent))
      (let [[child next] (parse-list lines j rewrite)]
        (array/push (last items) child)
        (set j next))

      # a marker at our level: the next item
      (and hit (= (length (hit 0)) indent))
      (do
        (def text (hit 2))
        (def boxed (checkbox text))
        (array/push items
                    (if boxed
                      @[:li (boxed 0) ;(rewrite-links (inline (boxed 1)) rewrite)]
                      @[:li ;(rewrite-links (inline text) rewrite)]))
        (++ j))

      # a continuation line: indented prose belonging to the last item
      (and (not (empty? (string/trim line)))
           (string/has-prefix? (string/repeat " " (+ indent 2)) line))
      (do
        (array/push (last items) " ")
        (array/push (last items) ;(rewrite-links (inline (string/trim line)) rewrite))
        (++ j))

      (break)))
  [[(if ordered :ol :ul) ;(map |(tuple ;$) items)] j])

(defn- parse-quote [lines i rewrite]
  (def inner @[])
  (var j i)
  (while (and (< j (length lines)) (string/has-prefix? ">" (lines j)))
    (def line (string/slice (lines j) 1))
    (array/push inner (if (string/has-prefix? " " line) (string/slice line 1) line))
    (++ j))
  [[:blockquote ;(blocks inner rewrite)] j])

(defn- parse-fence [lines i]
  # matched on the trimmed line: a fence indented under a list item is
  # still a fence, and the indent comes off the body by the same amount
  (def indent (- (length (lines i)) (length (string/triml (lines i)))))
  (def lang (or (first (peg/match fence-peg (string/trim (lines i)))) ""))
  (defn dedent [l] (if (<= (length l) indent) "" (string/slice l indent)))
  (def body @[])
  (var j (inc i))
  (while (and (< j (length lines)) (not (peg/match fence-peg (string/trim (lines j)))))
    (array/push body (dedent (lines j)))
    (++ j))
  [[:pre [:code (if (empty? lang) {} {:class (string "language-" lang)})
          (string (string/join body "\n") "\n")]]
   (min (length lines) (inc j))])

(varfn blocks
  "Lines to an array of block-level hiccup."
  [lines rewrite]
  (def out @[])
  (var i 0)
  (while (< i (length lines))
    (def line (lines i))
    (def trimmed (string/trim line))
    (cond
      (empty? trimmed)
      (++ i)

      (peg/match fence-peg trimmed)
      (let [[node next] (parse-fence lines i)]
        (array/push out node) (set i next))

      (peg/match header-peg line)
      (let [[hashes text] (peg/match header-peg line)
            level (length hashes)
            spans (rewrite-links (inline text) rewrite)]
        (array/push out
                    [(keyword (string "h" level))
                     {:id (slug (strip-markup spans))}
                     ;spans])
        (++ i))

      (peg/match hr-peg trimmed)
      (do (array/push out [:hr]) (++ i))

      (string/has-prefix? ">" line)
      (let [[node next] (parse-quote lines i rewrite)]
        (array/push out node) (set i next))

      (and (string/has-prefix? "|" trimmed)
           (< (inc i) (length lines))
           (string/has-prefix? "|" (string/trim (get lines (inc i) "")))
           (peg/match table-sep-peg (string/trim (get lines (inc i) ""))))
      (let [[node next] (parse-table lines i rewrite)]
        (array/push out node) (set i next))

      (peg/match item-peg line)
      (let [[node next] (parse-list lines i rewrite)]
        (array/push out node) (set i next))

      # a paragraph: everything until a blank line or another block
      (do
        (def para @[])
        (while (and (< i (length lines))
                    (let [l (lines i) t (string/trim l)]
                      (and (not (empty? t))
                           (not (peg/match fence-peg t))
                           (not (peg/match header-peg l))
                           (not (string/has-prefix? ">" l))
                           (not (peg/match item-peg l)))))
          (array/push para (string/trim (lines i)))
          (++ i))
        (array/push out [:p ;(rewrite-links (inline (string/join para " ")) rewrite)]))))
  out)

# -- the public face -----------------------------------------------------

(defn parse
  ``A Markdown document as an array of hiccup blocks.

      (parse src)
      (parse src {:rewrite-link (fn [url] ...)})

  The rewriter sees every link target exactly as written (relative .md
  paths included) and answers with what the page should carry.``
  [src &opt opts]
  (default opts {})
  (blocks (string/split "\n" src) (get opts :rewrite-link)))

(defn title
  "The text of the document's first # header, or nil."
  [src]
  (var found nil)
  (each line (string/split "\n" src)
    (when (nil? found)
      (when-let [m (peg/match header-peg line)]
        (when (= 1 (length (m 0)))
          (set found (strip-markup (inline (m 1))))))))
  found)
