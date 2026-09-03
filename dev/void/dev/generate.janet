### void/dev/generate — sample values from schemas.
###
### The :generator schema projection: walk a normalized schema node
### and produce a value that validates against it — the substrate for
### void/test factories (and, later, property-based testing). Honors
### :min/:max bounds, :enum members, :format for strings and resolves
### [:ref name] through the schema registry with a recursion depth
### cap. Schemas that only constrain by opaque predicates (:pred,
### :peg, :pattern) cannot be generated — the error says so; pass the
### value explicitly via factory overrides instead.

(import void/core/schema :as schema)

(def- alnum "abcdefghijklmnopqrstuvwxyz0123456789")
(def- hex "0123456789abcdef")

(var- default-rng (math/rng (% (math/floor (* 1000 (os/clock))) 0x7fffffff)))

(defn- rand-int [rng lo hi]
  (+ lo (math/rng-int rng (inc (- hi lo)))))

(defn- rand-chars [rng source n]
  (string/from-bytes
    ;(seq [_ :range [0 n]] (source (math/rng-int rng (length source))))))

(defn- pick [rng xs]
  (xs (math/rng-int rng (length xs))))

(defn- gen-format [rng fmt]
  (case fmt
    :email (string (rand-chars rng alnum 8) "@example.com")
    :uuid (string/format "%s-%s-%s-%s-%s"
                         (rand-chars rng hex 8) (rand-chars rng hex 4)
                         (rand-chars rng hex 4) (rand-chars rng hex 4)
                         (rand-chars rng hex 12))
    :date (string/format "%04d-%02d-%02d"
                         (rand-int rng 1990 2030)
                         (rand-int rng 1 12)
                         (rand-int rng 1 28))
    :uri (string "https://example.com/" (rand-chars rng alnum 6))
    (errorf "cannot generate a value for string format %q — pass it explicitly" fmt)))

(defn- gen-bytes [rng props to]
  (when (props :pattern)
    (error "cannot generate a value for a :pattern schema — pass it explicitly"))
  (if-let [fmt (props :format)]
    (to (gen-format rng fmt))
    (do
      (def lo (get props :min 1))
      (def hi (max lo (get props :max (+ lo 11))))
      (to (rand-chars rng alnum (rand-int rng (min lo hi) hi))))))

(defn- gen-number [rng props int?]
  (def lo (get props :min 0))
  (def hi (max lo (get props :max (+ lo 100))))
  (if int?
    (rand-int rng (math/ceil lo) (math/floor hi))
    (+ lo (* (math/rng-uniform rng) (- hi lo)))))

(var- gen nil)

(defn- gen-map [sch rng depth opts]
  (def out @{})
  (each [k sub] (sch :children)
    (def v (gen sub rng (inc depth) opts))
    (unless (and (nil? v) (= :optional (sub :type)))
      (put out k v)))
  out)

(defn- shuffle [rng xs]
  (def out (array ;xs))
  (loop [i :down-to [(dec (length out)) 1]]
    (def j (math/rng-int rng (inc i)))
    (def tmp (out i))
    (put out i (out j))
    (put out j tmp))
  out)

(defn- gen-union [sch rng depth opts]
  (def order (shuffle rng (sch :children)))
  (var result nil)
  (var done false)
  (var last-err nil)
  (each branch order
    (unless done
      (def [ok v] (protect (gen branch rng (inc depth) opts)))
      (if ok
        (do (set result v) (set done true))
        (set last-err v))))
  (unless done
    (errorf "cannot generate any :union branch: %s" (describe last-err)))
  result)

(defn- gen-and [sch rng depth opts]
  (def base (first (sch :children)))
  (var result nil)
  (var done false)
  (loop [_ :range [0 25] :until done]
    (def v (gen base rng (inc depth) opts))
    (when (schema/valid? sch v)
      (set result v)
      (set done true)))
  (unless done
    (error "cannot generate a value satisfying every :and branch — pass it explicitly"))
  result)

(set gen
  (fn gen [sch rng depth opts]
    (def props (sch :props))
    (if (> depth (get opts :max-depth 8))
      # recursion cap: back out through the nearest nullable shape
      (case (sch :type)
        :optional nil
        :vector []
        (errorf "generation exceeded :max-depth %d at a %q node"
                (get opts :max-depth 8) (sch :type)))
      (case (sch :type)
      :literal (props :value)
      :enum (pick rng (props :values))
      :union (gen-union sch rng depth opts)
      :and (gen-and sch rng depth opts)
      # optional: prefer a real value, but an ungeneratable inner
      # schema (bare :pred etc.) degrades to nil, which is also valid
      :optional (let [[ok v] (protect (gen (first (sch :children)) rng (inc depth) opts))]
                  (if ok v nil))
      :vector (do
                (def lo (get props :min 1))
                (def hi (max lo (get props :max (+ lo 2))))
                (tuple ;(seq [_ :range [0 (rand-int rng (min lo hi) hi)]]
                          (gen (first (sch :children)) rng (inc depth) opts))))
      :map (gen-map sch rng depth opts)
      :map-of (do
                (def [ks vs] (sch :children))
                (def out @{})
                (repeat 2
                  (put out (gen ks rng (inc depth) opts)
                       (gen vs rng (inc depth) opts)))
                out)
      :ref (do
             (def name ((sch :props) :name))
             (def target (or (schema/lookup name)
                             (errorf "cannot generate [:ref %q] — schema is not registered" name)))
             (gen target rng (inc depth) opts))
      :pred (error "cannot generate a value for a bare :pred schema — pass it explicitly")
      :peg (error "cannot generate a value for a :peg schema — pass it explicitly")
      :any (pick rng [42 "sample" :sample true])
      :nil nil
      :boolean (= 1 (math/rng-int rng 2))
      :int (gen-number rng props true)
      :number (gen-number rng props false)
      :string (gen-bytes rng props identity)
      :bytes (gen-bytes rng props identity)
      :buffer (gen-bytes rng props buffer)
      :keyword (keyword (rand-chars rng alnum 6))
      :symbol (symbol (rand-chars rng alnum 6))
      :tuple []
      :array @[]
      :indexed []
      :table @{}
      :struct {}
      :dictionary @{}
      :function (fn generated [&] nil)
      (errorf "cannot generate a value for schema type %q — pass it explicitly"
              (sch :type))))))

(defn generate
  ``Generate a sample value that validates against the schema:

      (generate {:email [:string {:format :email}] :age [:int {:min 18}]})

  Options:
    :seed       integer — reproducible output (fresh rng per call)
    :rng        an existing math/rng (overrides :seed)
    :max-depth  recursion cap for recursive [:ref ...] schemas
                (default 8; :optional/:vector back out as nil/[])

  Throws on schemas that only constrain by opaque predicates (:pred,
  :peg, string :pattern) — supply those values explicitly.``
  [sch &opt opts]
  (default opts {})
  (def rng (or (get opts :rng)
               (if-let [s (get opts :seed)] (math/rng s) default-rng)))
  (gen (schema/normalize sch) rng 0 opts))

(defn projection
  "The :generator projection body: (schema/project :generator User {:seed 7})."
  [sch &opt opts]
  (generate sch opts))

# registered on module load so void/test works without a full plugin
# bootstrap; the void/dev manifest also contributes it to
# :void.core/schema-projection (same registration, dogfooded).
(schema/register-projection! :generator projection)
