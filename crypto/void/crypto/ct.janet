### void/crypto/ct — comparison that does not leak by timing.
###
### `(= a b)` on strings stops at the first differing byte, and that is
### a side channel: an attacker who can submit guesses learns a token
### one byte at a time. The correct comparison is `CRYPTO_memcmp`, and
### it is here rather than as a Janet loop for the reason the package
### gives about every other primitive — on a bytecode VM "this loop is
### constant-time" is not a claim anybody can honour. The VM decides
### when to check for interrupts, the GC decides when to run, and the
### string comparison the JIT-less interpreter performs is not the one
### written in the source.
###
### Length is not a secret here and is compared normally: every token
### void issues has a fixed length, so a length mismatch means "not
### our token" rather than "you are close".

(import ./lib :as lib)

(defn equal?
  ``True when two byte sequences are equal, compared in time that does
  not depend on *where* they differ. Use it for every secret: tokens,
  signatures, one-time codes.``
  [a b]
  (lib/ensure!)
  (def x (string a))
  (def y (string b))
  (and (= (length x) (length y))
       (zero? (lib/CRYPTO_memcmp x y (length x)))))
