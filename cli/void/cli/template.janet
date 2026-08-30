### void/cli/template — the one thing `void new` and `void make` share.
###
### A template here is a long string with `{{key}}` holes and a
### dictionary that fills them. It is deliberately not a templating
### language: there are no conditionals and no loops in the text,
### because every decision a generator makes — which relations exist,
### which field wants a textarea, whether a profile carries void/dev —
### is made in Janet and arrives as one already-rendered string.
###
### Two properties matter and both come from being this small. The
### text of a generated file reads, in the source, exactly as it will
### read on disk: nobody has to run the generator to see what it
### writes. And a project that wants more than a hole filled replaces
### the whole entry (see void/cli/make's `override`) rather than
### reaching for a feature this file would otherwise have to grow.
###
### The delimiter is three backticks, so a generated file may contain
### the single and double backticks that Janet docstrings are written
### with — which the templates it generates are full of.

(defn fill
  ``Fill `{{key}}` holes from a dictionary. Substitution is one pass
  left to right, so a value that happens to contain `{{` is data
  rather than a further hole; a hole with no value is an error, since
  the alternative is a generated file with a `{{name}}` in it.``
  [tmpl subs]
  (def out @"")
  (var i 0)
  (def n (length tmpl))
  (while (< i n)
    (def open (string/find "{{" tmpl i))
    (def close (when open (string/find "}}" tmpl open)))
    (if (nil? close)
      (do (buffer/push-string out (string/slice tmpl i)) (set i n))
      (let [key (keyword (string/slice tmpl (+ open 2) close))]
        (buffer/push-string out (string/slice tmpl i open))
        (buffer/push-string out
                            (string (or (get subs key)
                                        (errorf "template hole %q has no value" key))))
        (set i (+ close 2)))))
  (string out))

(defn render
  ``Fill a template and end the result with a newline — janet drops the
  one before a long string's closing delimiter, and a generated file
  that ends without it is the only file in the tree that does.``
  [tmpl subs]
  (string (fill tmpl subs) "\n"))
