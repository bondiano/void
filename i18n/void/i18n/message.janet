### void/i18n/message — message rendering: named {param} interpolation and
### plural-form selection. Positions were rejected in the ADR — a
### translation reorders words, and with them printf's argument order.
###
### The interpolation itself is `void/core/text`'s: the framework's own
### packages render their own tables without this plugin composed, and
### two readers of one syntax may not be two implementations of it.
### What lives here is the half that needs a catalog — CLDR plural
### categories.

(import void/core/text :as text)

(def interpolate
  "See text/interpolate — {name} placeholders, {{ and }} literal, a
  missing parameter visible rather than fatal."
  text/interpolate)

(defn render
  {:params [(or :string {:keyword :string})
            (or {:count :number? & r} :nil)
            (fn [:number] :keyword)]
   :ret :string}
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
