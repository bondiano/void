### void/i18n/plural — CLDR plural categories for the shipped language
### families. A rule is (fn [n] category) over the CLDR keywords :zero
### :one :two :few :many :other; a language beyond this table contributes
### {:language :categories} to :void.i18n/plural, and an unknown one
### declines as one/other — the honest default, named in the ADR as the
### price of not shipping CLDR whole.

(defn- int-n?
  {:params [:any] :ret :boolean :narrows :number}
  "True when `n` is a number equal to its own floor — an integer
  value, though not necessarily Janet's integer type. Guards the
  rules below that only make sense on whole counts."
  [n] (and (number? n) (= n (math/floor n))))

(defn one-other
  {:params [:number] :ret (enum :one :other)}
  "The default rule: 1 is :one, everything else :other."
  [n]
  (if (= n 1) :one :other))

(defn- no-plural
  {:params [:any] :ret (enum :other)}
  "The rule for a language with no plural distinction at all: every
  count declines as :other."
  [_] :other)

(defn- zero-through-one
  {:params [:any] :ret (enum :one :other)}
  "The French/Portuguese rule: 0, 0.5 and 1 all take the singular —
  i = 0..1 declines as :one, everything else :other."
  # fr, pt: i = 0..1 -> one (0, 0.5 and 1 all say "1 jour" grammar-wise)
  [n]
  (if (and (number? n) (>= n 0) (< n 2)) :one :other))

(defn- slavic
  {:params [:number] :ret (enum :one :few :many :other)}
  "The Slavic rule shared by ru, uk, be, sr, hr and bs: a fraction is
  :other; among integers, a units digit of 1 (except the teens) is
  :one, 2-4 (except 12-14) is :few, and everything else is :many."
  # ru uk be sr hr bs: 21 -> one, 2-4/22-24 -> few, 5-20/25-30 -> many,
  # teens are many, fractions are other
  [n]
  (if-not (int-n? n)
    :other
    (let [a (math/abs n) m10 (% a 10) m100 (% a 100)]
      (cond
        (and (= 1 m10) (not= 11 m100)) :one
        (and (>= m10 2) (<= m10 4) (or (< m100 12) (> m100 14))) :few
        :many))))

(defn- polish
  {:params [:number] :ret (enum :one :few :many :other)}
  "Like `slavic`, but only exactly 1 declines as :one — 21, which the
  Slavic rule calls :one, is :many here."
  # like slavic, but only exactly 1 is :one (21 is :many)
  [n]
  (if-not (int-n? n)
    :other
    (let [a (math/abs n) m10 (% a 10) m100 (% a 100)]
      (cond
        (= 1 a) :one
        (and (>= m10 2) (<= m10 4) (or (< m100 12) (> m100 14))) :few
        :many))))

(defn- czech
  {:params [:number] :ret (enum :one :few :many :other)}
  "The Czech/Slovak rule: 1 is :one, 2-4 is :few, a fraction is
  :many, and everything else is :other."
  # cs sk: 1 -> one, 2-4 -> few, fractions -> many, the rest -> other
  [n]
  (cond
    (not (int-n? n)) :many
    (= 1 n) :one
    (and (>= n 2) (<= n 4)) :few
    :other))

(defn- arabic
  {:params [:number] :ret (enum :zero :one :two :few :many :other)}
  "The Arabic rule: 0 is :zero, 1 is :one, 2 is :two, a last-two-digits
  value of 3-10 is :few, 11-99 is :many, and a fraction or anything
  else is :other."
  [n]
  (if-not (int-n? n)
    :other
    (let [m100 (% n 100)]
      (cond
        (= 0 n) :zero
        (= 1 n) :one
        (= 2 n) :two
        (and (>= m100 3) (<= m100 10)) :few
        (and (>= m100 11) (<= m100 99)) :many
        :other))))

(def rules
  "Primary language -> rule for the shipped families; anything absent
  here declines as `one-other`."
  {:ru slavic :uk slavic :be slavic :sr slavic :hr slavic :bs slavic
   :pl polish
   :cs czech :sk czech
   :fr zero-through-one :pt zero-through-one
   :ja no-plural :zh no-plural :ko no-plural :th no-plural
   :vi no-plural :id no-plural :ms no-plural
   :ar arabic})
