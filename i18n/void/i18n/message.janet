### void/i18n/message — message rendering: named {param} interpolation and
### plural-form selection. Positions were rejected in the ADR — a
### translation reorders words, and with them printf's argument order.
### "{{" escapes a literal brace; an absent parameter stays "{name}"
### verbatim — visible on the page, never a crash: an error message
### renders from an attacker-controlled value and has no right to reach a
### 500.

(def- interp-peg
  (peg/compile
    ~{:main (any (+ :esc :ph :text :brace))
      :esc (+ (/ '"{{" "{") (/ '"}}" "}"))
      :ph (group (* "{" '(some (if-not (set "{}") 1)) "}"))
      :text '(some (if-not (set "{}") 1))
      :brace '(set "{}")}))

(defn interpolate
  "Render {name} placeholders of a template from params (keyword keys);
  a missing parameter stays {name} verbatim, {{ and }} are literal
  braces."
  [tmpl params]
  (def out @"")
  (each part (peg/match interp-peg tmpl)
    (if (bytes? part)
      (buffer/push out part)
      (let [name (first part)
            v (get (or params {}) (keyword name))]
        (buffer/push out (if (nil? v) (string "{" name "}") (string v))))))
  (string out))

(defn render
  ``One message to a string. A plural table ({:one .. :few .. :other ..})
  selects its form by `(category-of (params :count))` — no :count, or a
  category the table does not carry, falls back to :other (required at
  merge time); a plain string interpolates as is. :count stays
  available as {count}.``
  [msg params category-of]
  (if (dictionary? msg)
    (let [n (get (or params {}) :count)
          cat (if (number? n) (category-of n) :other)]
      (interpolate (or (get msg cat) (msg :other)) params))
    (interpolate msg params)))
