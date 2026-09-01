### void/i18n/plural — CLDR plural categories for the shipped language
### families (ADR-0036). A rule is (fn [n] category) over the CLDR
### keywords :zero :one :two :few :many :other; a language beyond this
### table contributes {:language :categories} to :void.i18n/plural, and
### an unknown one declines as one/other — the honest default, named
### in the ADR as the price of not shipping CLDR whole.

(defn- int-n? [n] (and (number? n) (= n (math/floor n))))

(defn one-other
  "The default rule: 1 is :one, everything else :other."
  [n]
  (if (= n 1) :one :other))

(defn- no-plural [_] :other)

(defn- zero-through-one
  # fr, pt: i = 0..1 -> one (0, 0.5 and 1 all say "1 jour" grammar-wise)
  [n]
  (if (and (number? n) (>= n 0) (< n 2)) :one :other))

(defn- slavic
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
  # cs sk: 1 -> one, 2-4 -> few, fractions -> many, the rest -> other
  [n]
  (cond
    (not (int-n? n)) :many
    (= 1 n) :one
    (and (>= n 2) (<= n 4)) :few
    :other))

(defn- arabic [n]
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
