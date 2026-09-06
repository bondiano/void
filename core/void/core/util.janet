### void/core/util — the four helpers every package had copied.
###
### `callable?` was written twenty-five times, `names-str` eight,
### `unique-by` twice and the did-you-mean pair (`levenshtein`,
### `suggest`) twice, each copy private to its module and every one of
### them identical. A helper that has to be re-typed to be used is a
### helper that drifts — one copy accepting cfunctions and the next
### not, one sorting names and the next not — and the message a user
### reads then depends on which module happened to catch the mistake.
### Here they are written once, and a package imports them.
###
### The module has no imports of its own: it sits under errors, schema
### and plugin alike, so it must not need any of them.

(defn callable?
  "Can `x` be called: a Janet function or a C function. Neither
  `function?` alone (a driver's `:execute` may be a cfunction) nor
  anything looser (a table with a `:call` key is not a handler)."
  [x]
  (or (function? x) (cfunction? x)))

(defn names-str
  ``The names in `names`, sorted and `%q`-quoted, joined by one space —
  the tail of every "unknown X (known: ...)" message, so a typo is
  reported against a list a reader can scan:

      (names-str [:b :a])  ; => ":a :b"``
  [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

(defn unique-by
  ``A `:validate` for an extension point whose contributions must not
  repeat a key: `(unique-by "middleware name" |($ :name))` refuses the
  second contribution with the same `:name` and says which. `what`
  names the key in the message; `f` reads it off a contribution.``
  [what f]
  (fn [contribs]
    (def seen @{})
    (each c contribs
      (def k (f c))
      (when (in seen k)
        (errorf "duplicate %s %q" what k))
      (put seen k true))))

(defn err-str
  ``The text of a caught error for a message that quotes it: a string
  error as it is, anything else (an errors/ envelope, a schema
  struct, a fiber's value) through `describe`. What `protect`'s second
  value looks like in a "failed: %s" report — written here once
  instead of once per module that batches errors.``
  [e]
  (if (string? e) e (describe e)))

# -- did-you-mean --------------------------------------------------------

(defn levenshtein
  "The edit distance between two strings: insertions, deletions and
  substitutions, each costing one."
  [a b]
  (def lb (length b))
  (var prev (seq [j :range [0 (inc lb)]] j))
  (for i 1 (inc (length a))
    (def cur @[i])
    (for j 1 (inc lb)
      (array/push cur
                  (min (inc (cur (dec j)))
                       (inc (prev j))
                       (+ (prev (dec j))
                          (if (= (a (dec i)) (b (dec j))) 0 1)))))
    (set prev cur))
  (prev lb))

(defn closest
  ``The candidate nearest to `name`, or nil when none is near enough
  to be what the writer meant: at most three edits away, and fewer
  edits than the name has characters (so a two-letter typo is not
  "corrected" into an unrelated two-letter name). Ties go to the
  first in sorted order, so the answer does not depend on how the
  candidates were collected.``
  [name candidates]
  (def s (string name))
  (var best nil)
  (var best-d math/inf)
  (each c (sorted candidates)
    (def d (levenshtein s (string c)))
    (when (< d best-d) (set best-d d) (set best c)))
  (when (and best (<= best-d 3) (< best-d (length s)))
    best))

(defn suggest
  ``The did-you-mean tail of an "unknown name" message: `" — did you
  mean :foo?"` when a candidate is close (see `closest`), and the
  empty string otherwise — so a message can always append it.``
  [name candidates]
  (if-let [best (closest name candidates)]
    (string/format " — did you mean %q?" best)
    ""))
