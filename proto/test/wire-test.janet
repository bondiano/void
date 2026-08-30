(import ../test-support/paths)
(import void/proto/wire :as wire)

(defn- hex [bs] (string/join (map |(string/format "%02x" $) bs) ""))
(defn- varint [v] (hex (wire/encode-varint @"" v)))
(defn- read-varint [s] (first (wire/decode-varint s 0)))

# -- varint, against the numbers the specification prints ----------------

(assert (= "00" (varint 0)))
(assert (= "01" (varint 1)))
(assert (= "7f" (varint 127)))
(assert (= "8001" (varint 128)))
(assert (= "ac02" (varint 300)) "the 300 every protobuf page opens with")
(assert (= "ffffffffffffffffff01" (varint -1))
        "a negative varint is the ten-byte two's complement, which is the format's own wart")

(each n [0 1 127 128 300 65535 2147483647 9007199254740991]
  (assert (= n (read-varint (wire/encode-varint @"" n)))
          (string/format "%q survives a varint round trip" n)))

(assert (= 0 (compare (int/u64 "18446744073709551615")
                      (read-varint (wire/encode-varint @"" (int/u64 "18446744073709551615")))))
        "the largest uint64 there is comes back whole")

# a number that has stopped naming one integer is refused rather than
# rounded — the caller has an int/s64 for that
(assert (not (first (protect (wire/encode-varint @"" 1e300))))
        "a double past 2^53 is not written as if it were exact")
(assert (= 0 (compare (int/s64 "9007199254740993")
                      (read-varint (wire/encode-varint @"" (int/s64 "9007199254740993")))))
        "and the int/s64 that does name it round-trips")

# below 2^53 a decoded varint is an ordinary number, past it an int
(assert (number? (read-varint (wire/encode-varint @"" 4294967296))))
(assert (not (number? (read-varint (wire/encode-varint @"" (int/s64 "72057594037927936"))))))

# -- truncation is an error, not a shorter message ------------------------

(assert (not (first (protect (wire/decode-varint "\x80\x80" 0))))
        "a varint that never ends is a truncated message")
(assert (not (first (protect (wire/decode-bytes "\x05ab" 0))))
        "a length prefix longer than what follows is a truncated message")
(assert (not (first (protect (wire/decode-fixed64 "\x01\x02" 0)))))

# -- zigzag ---------------------------------------------------------------

(assert (= "00" (hex (wire/encode-varint @"" (wire/zigzag 0)))))
(assert (= "01" (hex (wire/encode-varint @"" (wire/zigzag -1)))))
(assert (= "02" (hex (wire/encode-varint @"" (wire/zigzag 1)))))
(assert (= "03" (hex (wire/encode-varint @"" (wire/zigzag -2)))))
(each n [0 -1 1 -2 2 63 -64 2147483647 -2147483648 4503599627370495]
  (assert (= n (wire/unzigzag (wire/zigzag n)))
          (string/format "zigzag round-trips %q" n)))
(assert (= 0 (compare (int/s64 "-9223372036854775808")
                      (wire/unzigzag (wire/zigzag (int/s64 "-9223372036854775808")))))
        "including the int64 that has no positive twin")

# -- fixed width ----------------------------------------------------------

(assert (= "01000000" (hex (wire/encode-fixed32 @"" 1))) "little-endian, as the format says")
(assert (= "0100000000000000" (hex (wire/encode-fixed64 @"" 1))))
(assert (= 4294967295 (first (wire/decode-fixed32 (wire/encode-fixed32 @"" -1) 0)))
        "a fixed32 reads back unsigned; the field's signedness is the codec's business")

# -- IEEE 754, written out by hand ---------------------------------------
#
# The bit patterns are the standard's, so a mistake in ./wire shows up
# here rather than as a number that is nearly right.

(assert (= "0000803f" (hex (wire/encode-float @"" 1.0))))
(assert (= "000000000000f03f" (hex (wire/encode-double @"" 1.0))))
(assert (= "0000c03f" (hex (wire/encode-float @"" 1.5))))
(assert (= "00000000000004c0" (hex (wire/encode-double @"" -2.5))))
(assert (= "00000000" (hex (wire/encode-float @"" 0.0))))
# Janet's reader gives -0.0 the sign of positive zero, so the negative
# one is built rather than written
(assert (= "00000080" (hex (wire/encode-float @"" (- 0.0)))) "negative zero keeps its sign")
(assert (= "0000807f" (hex (wire/encode-float @"" math/inf))))
(assert (= "000080ff" (hex (wire/encode-float @"" (- math/inf)))))

(each x [0.0 1.0 -1.0 0.5 3.14159265358979 1e300 -1e-300 5e-324 math/inf (- math/inf)]
  (assert (= x (first (wire/decode-double (wire/encode-double @"" x) 0)))
          (string/format "%q survives a double round trip" x)))
# a float32 holds these exactly, so the round trip is equality
(each x [0.0 1.0 -1.0 0.5 0.25 3.5 -1024.0]
  (assert (= x (first (wire/decode-float (wire/encode-float @"" x) 0)))
          (string/format "%q survives a float round trip" x)))
# and where it does not, it rounds to the nearest float32 rather than
# to something else
(each x [0.1 3.4e38 -1.7e-38]
  (def back (first (wire/decode-float (wire/encode-float @"" x) 0)))
  (assert (< (math/abs (- x back)) (* 1e-7 (math/abs x)))
          (string/format "%q rounds to the nearest float32, got %q" x back)))
(assert (= "01000000" (hex (wire/encode-float @"" 1e-45)))
        "the smallest positive subnormal is one bit, and it is that bit")
(assert (= "00000000" (hex (wire/encode-float @"" 1e-60)))
        "and a magnitude below even that rounds to zero rather than to nonsense")
(assert (let [n (first (wire/decode-double (wire/encode-double @"" math/nan) 0))] (not= n n))
        "a NaN stays a NaN")

# -- tags -----------------------------------------------------------------

(assert (= "08" (hex (wire/encode-tag @"" 1 :varint))))
(assert (= "12" (hex (wire/encode-tag @"" 2 :length))))
(assert (= [1 :varint 1] (wire/decode-tag "\x08" 0)))
(assert (not (first (protect (wire/decode-tag "\x00" 0))))
        "field number 0 does not exist")
(def group-tag (wire/encode-tag @"" 1 :varint))
(put group-tag 0 0x0b)                                     # wire type 3: a group
(def [ok err] (protect (wire/decode-tag group-tag 0)))
(assert (not ok))
(assert (string/find "group" err) "a group says it is a group, not \"unknown wire type 3\"")

# -- skipping -------------------------------------------------------------

(assert (= 2 (wire/skip-value "\xac\x02\xff" 0 :varint))
        "a skipped varint ends where its continuation bits end")
(assert (= 4 (wire/skip-value "\x03abc\xff" 0 :length))
        "a skipped length-delimited run ends after its bytes")

(print "wire ok")
