### void/proto/wire — the protobuf wire format (SPEC.md §5.7,
### ADR-0013).
###
### The bottom of the package: bytes in, bytes out, and no idea what a
### message is. Everything above it — ./codec, ./json, the parser —
### speaks descriptors; this module speaks varints, tags and the four
### wire types the format actually has, so the layer that will one day
### be C (ADR-0013: "varint-ядро — кандидат на C по бюджетам §8") is
### the layer with no policy in it.
###
### **Where the 64-bit honesty lives.** A Janet number is a double, so
### it holds every integer up to 2^53 and lies about the rest. An
### `int64` that does not fit comes back as an `int/s64` (a `uint64` as
### an `int/u64`) rather than rounded — the policy void/db-postgres
### already applies to Postgres' int8, and for the same reason. Below
### 2^53 the decoders return plain numbers, because that is what a
### caller wants to do arithmetic with, and the encoders take either.
###
### **The fast path is arithmetic, not abstract types.** Janet's bit
### operations are 32-bit (`(band 1099511627776 1)` is an error), so a
### varint over an ordinary number is written with `%` and `/` and
### allocates nothing; only a negative or a genuinely 64-bit value
### drops into `int/u64`, where every step allocates. That split is
### the whole performance story of this file (§8.5 rule 2).
###
### Every reader takes `[bytes idx]` and returns `[value next-idx]`;
### running off the end is an error rather than a nil, because a
### truncated message is not a shorter message.

(def max-exact
  ``2^53 — past this a double no longer represents every integer, so a
  64-bit field comes back as an int/s64 or an int/u64 instead. The
  same constant void/db-postgres uses for int8.``
  9007199254740992)

(def wire-types
  "The wire types protobuf has, by their tag bits."
  {0 :varint 1 :fixed64 2 :length 5 :fixed32})

(def wire-type-numbers
  "The tag bits of each wire type."
  {:varint 0 :fixed64 1 :length 2 :fixed32 5})

(defn- eof [idx]
  (errorf "proto wire: message ends inside a value at byte %d" idx))

# -- integers, in and out ------------------------------------------------

(defn- as-u64
  ``The unsigned 64-bit reading of a Janet integer value: a negative
  number is its two's complement, which is what protobuf writes for a
  negative int32/int64 (ten bytes of varint, the format's own famous
  wart).``
  [v]
  (case (type v)
    :core/u64 v
    :core/s64 (int/u64 v)
    :number (do
              (unless (< (math/abs v) max-exact)
                (errorf (string "proto wire: the double %q is past 2^53 and no longer names "
                                "one integer — pass an int/s64 (or an int/u64) to write it exactly")
                        v))
              (if (< v 0) (int/u64 (int/s64 v)) (int/u64 v)))
    (errorf "proto wire: %q is not an integer" v)))

(defn narrow
  ``A 64-bit integer as a plain number when one can hold it exactly,
  and untouched when it cannot. The one place the "number, or an
  int/s64 past 2^53" policy is spelled. A value that is already a
  number is already narrow.``
  [v]
  (cond
    (number? v) v
    (and (compare< v max-exact) (compare< (- max-exact) v)) (int/to-number v)
    v))

(defn integer-value?
  "Is this a value the integer writers accept — a whole number, an
  int/s64 or an int/u64?"
  [v]
  (case (type v)
    :core/u64 true
    :core/s64 true
    :number (and (not= v math/inf) (not= v (- math/inf))
                 (= v (math/trunc v)))
    false))

# -- varint --------------------------------------------------------------

(defn encode-varint
  ``Append `v` to `buf` as a base-128 varint. Numbers below 2^53 take
  the arithmetic path and allocate nothing; anything negative or truly
  64-bit goes through int/u64, where a negative value is ten bytes.``
  [buf v]
  (if (and (number? v) (>= v 0) (< v max-exact))
    (do
      (var n v)
      (while (>= n 128)
        (buffer/push-byte buf (bor 0x80 (% n 128)))
        (set n (math/floor (/ n 128))))
      (buffer/push-byte buf n))
    (do
      (var n (as-u64 v))
      (while (compare> n 127)
        (buffer/push-byte buf (bor 0x80 (int/to-number (band n 0x7f))))
        (set n (brshift n 7)))
      (buffer/push-byte buf (int/to-number n))))
  buf)

(defn decode-varint
  ``Read a varint at `idx`. Returns [value next-idx] with the value as
  a plain number when it fits in one and as an int/u64 when it does
  not — see `narrow`.``
  [bytes idx]
  (def n (length bytes))
  (var i idx)
  # groups are collected first: how many there are decides whether the
  # value can be assembled in doubles (7 groups = 49 bits) or has to
  # go through int/u64
  (var count 0)
  (var acc 0)
  (var mult 1)
  (var big nil)
  (var done false)
  (while (not done)
    (when (>= i n) (eof idx))
    (def b (in bytes i))
    (++ i)
    (++ count)
    (when (> count 10)
      (errorf "proto wire: varint at byte %d is longer than ten bytes" idx))
    (if (<= count 7)
      (do (set acc (+ acc (* (band b 0x7f) mult)))
          (set mult (* mult 128)))
      (do
        (when (nil? big) (set big (int/u64 acc)))
        (set big (bor big (blshift (int/u64 (band b 0x7f))
                                   (* 7 (dec count)))))))
    (when (zero? (band b 0x80)) (set done true)))
  [(if big (narrow big) acc) i])

(defn skip-varint
  "Step over a varint without building its value."
  [bytes idx]
  (def n (length bytes))
  (var i idx)
  (while (and (< i n) (not (zero? (band (in bytes i) 0x80)))) (++ i))
  (when (>= i n) (eof idx))
  (inc i))

# -- zigzag (sint32 / sint64) --------------------------------------------

(defn zigzag
  "The zigzag encoding of a signed integer: small magnitudes become
  small varints whichever side of zero they are on."
  [v]
  (if (and (number? v) (< (math/abs v) (/ max-exact 2)))
    (if (< v 0) (- (* -2 v) 1) (* 2 v))
    (let [s (int/s64 v)]
      (int/u64 (bxor (blshift s 1) (brshift s 63))))))

(defn unzigzag
  "The signed integer behind a zigzag varint."
  [v]
  (if (and (number? v) (< v max-exact))
    (if (odd? v) (- (/ (+ v 1) 2)) (/ v 2))
    (let [u (as-u64 v)]
      (narrow (bxor (int/s64 (brshift u 1))
                    (- (int/s64 (band u 1))))))))

# -- fixed width ---------------------------------------------------------

(defn encode-fixed32
  "Append the low 32 bits of `v`, little-endian."
  [buf v]
  (var n (if (number? v)
           (if (< v 0) (+ v 4294967296) v)
           (int/to-number (band (as-u64 v) 0xffffffff))))
  (loop [_ :range [0 4]]
    (buffer/push-byte buf (% n 256))
    (set n (math/floor (/ n 256))))
  buf)

(defn decode-fixed32
  "Read four little-endian bytes as an unsigned 32-bit number."
  [bytes idx]
  (when (> (+ idx 4) (length bytes)) (eof idx))
  [(+ (in bytes idx)
      (* 256 (in bytes (+ idx 1)))
      (* 65536 (in bytes (+ idx 2)))
      (* 16777216 (in bytes (+ idx 3))))
   (+ idx 4)])

(defn encode-fixed64
  "Append eight little-endian bytes of `v`."
  [buf v]
  (buffer/push buf (int/to-bytes (as-u64 v) :le))
  buf)

(defn decode-fixed64
  "Read eight little-endian bytes as an int/u64."
  [bytes idx]
  (when (> (+ idx 8) (length bytes)) (eof idx))
  (var v (int/u64 0))
  (loop [i :down-to [(+ idx 7) idx]]
    (set v (bor (blshift v 8) (int/u64 (in bytes i)))))
  [v (+ idx 8)])

# -- IEEE 754, by hand ---------------------------------------------------
#
# Janet can neither pack nor unpack a float: `int/to-bytes` takes
# integers only and `marshal` is Janet's own format, not the machine's.
# So the two formats are written out — which also means the result does
# not depend on the host's endianness or on a native module, and the
# suite can assert on the bit patterns the standard prints.

(defn- float-bits [x mantissa-bits exponent-bits]
  (def bias (dec (blshift 1 (dec exponent-bits))))
  (def max-exp (dec (blshift 1 exponent-bits)))
  (def mant-scale (math/pow 2 mantissa-bits))
  (def sign (if (or (< x 0) (and (= x 0) (= (- math/inf) (/ 1 x)))) 1 0))
  (def a (math/abs x))
  (def [e m]
    (cond
      (not= x x) [max-exp (/ mant-scale 2)]              # NaN, quiet
      (= a math/inf) [max-exp 0]
      (= a 0) [0 0]
      (let [[frac exp] (math/frexp a)
            unbiased (+ (dec exp) bias)]
        (cond
          # overflows the format: the nearest representable is infinity
          (>= unbiased max-exp) [max-exp 0]
          # subnormal: no implicit leading one, the exponent field is 0
          (<= unbiased 0)
          (let [scaled (math/round (* frac (math/pow 2 (+ mantissa-bits unbiased))))]
            (if (>= scaled mant-scale) [1 0] [0 scaled]))
          (let [scaled (math/round (* (- (* frac 2) 1) mant-scale))]
            # rounding the mantissa up can carry into the exponent
            (if (>= scaled mant-scale)
              (if (>= (inc unbiased) max-exp) [max-exp 0] [(inc unbiased) 0])
              [unbiased scaled]))))))
  [sign e m])

(defn- float-value [sign e m mantissa-bits exponent-bits]
  (def bias (dec (blshift 1 (dec exponent-bits))))
  (def max-exp (dec (blshift 1 exponent-bits)))
  (def mant-scale (math/pow 2 mantissa-bits))
  (def magnitude
    (cond
      (= e max-exp) (if (zero? m) math/inf math/nan)
      (zero? e) (math/ldexp (/ m mant-scale) (- 1 bias))
      (math/ldexp (+ 1 (/ m mant-scale)) (- e bias))))
  (if (zero? sign) magnitude (- magnitude)))

(defn encode-float
  "Append `x` as a 32-bit IEEE 754 float, little-endian."
  [buf x]
  (def [sign e m] (float-bits x 23 8))
  (encode-fixed32 buf (+ (* sign 2147483648) (* e 8388608) m)))

(defn decode-float
  "Read four little-endian bytes as a 32-bit IEEE 754 float."
  [bytes idx]
  (def [bits next] (decode-fixed32 bytes idx))
  (def sign (math/floor (/ bits 2147483648)))
  (def e (% (math/floor (/ bits 8388608)) 256))
  (def m (% bits 8388608))
  [(float-value sign e m 23 8) next])

(defn encode-double
  "Append `x` as a 64-bit IEEE 754 double, little-endian."
  [buf x]
  (def [sign e m] (float-bits x 52 11))
  (def bits (bor (blshift (int/u64 sign) 63)
                 (blshift (int/u64 e) 52)
                 (int/u64 m)))
  (encode-fixed64 buf bits))

(defn decode-double
  "Read eight little-endian bytes as a 64-bit IEEE 754 double."
  [bytes idx]
  (def [bits next] (decode-fixed64 bytes idx))
  (def sign (int/to-number (brshift bits 63)))
  (def e (int/to-number (band (brshift bits 52) 0x7ff)))
  (def m (int/to-number (band bits (int/u64 "4503599627370495"))))
  [(float-value sign e m 52 11) next])

# -- tags and length-delimited bytes -------------------------------------

(defn encode-tag
  "Append the tag of field `number` with wire type `wtype`."
  [buf number wtype]
  (def bits (or (wire-type-numbers wtype)
                (errorf "proto wire: unknown wire type %q" wtype)))
  (encode-varint buf (+ (* number 8) bits)))

(defn decode-tag
  ``Read a tag: [field-number wire-type next-idx]. A field number of
  zero, or one of the two group wire types, is refused here rather
  than three layers up — groups were removed from the language in
  proto3 and void/proto never wrote one.``
  [bytes idx]
  (def [v next] (decode-varint bytes idx))
  (unless (number? v)
    (errorf "proto wire: field tag at byte %d is not a 32-bit tag" idx))
  (def number (math/floor (/ v 8)))
  (def bits (% v 8))
  (when (zero? number)
    (errorf "proto wire: field number 0 at byte %d" idx))
  (def wtype (wire-types bits))
  (unless wtype
    (if (or (= bits 3) (= bits 4))
      (errorf "proto wire: field %d at byte %d is a group, and void/proto speaks proto3, where groups do not exist"
              number idx)
      (errorf "proto wire: field %d at byte %d has unknown wire type %d" number idx bits)))
  [number wtype next])

(defn encode-bytes
  "Append `bs` length-delimited."
  [buf bs]
  (encode-varint buf (length bs))
  (buffer/push buf bs)
  buf)

(defn decode-bytes
  "Read a length-delimited run: [string next-idx]."
  [bytes idx]
  (def [len next] (decode-varint bytes idx))
  (unless (number? len)
    (errorf "proto wire: length prefix at byte %d does not fit in memory" idx))
  (def stop (+ next len))
  (when (> stop (length bytes)) (eof idx))
  [(string/slice bytes next stop) stop])

(defn skip-value
  ``Step over one value of `wtype` at `idx` and return the index after
  it — what a decoder does with a field number it has never heard of.``
  [bytes idx wtype]
  (case wtype
    :varint (skip-varint bytes idx)
    :fixed32 (let [stop (+ idx 4)]
               (when (> stop (length bytes)) (eof idx))
               stop)
    :fixed64 (let [stop (+ idx 8)]
               (when (> stop (length bytes)) (eof idx))
               stop)
    :length (let [[len next] (decode-varint bytes idx)
                  stop (+ next len)]
              (when (> stop (length bytes)) (eof idx))
              stop)
    (errorf "proto wire: cannot skip wire type %q" wtype)))
