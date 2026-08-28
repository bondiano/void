### void/crypto/encode — the encodings tokens travel in (RFC 4648).
###
### Not cryptography, and deliberately kept apart from it: base64url is
### an alphabet, and putting it next to the KDF would suggest it does
### something for secrecy. It is here because every consumer of this
### package — a session token, a JWS segment, a PHC salt — needs the
### *same* spelling, and RFC 4648 §5 (URL-safe alphabet, no padding) is
### the one every other stack uses in exactly these places.
###
### The transform runs over spork's base64, which is C, rather than over
### a hand-rolled table: the standard alphabet and the URL-safe one
### differ in two characters and the padding rule, so the honest
### implementation is a translation of a tested encoder, not a second
### encoder.

(import spork/base64)

(defn base64url
  ``Encode bytes as base64url without padding (RFC 4648 §5) — the
  spelling JWS, PHC and every cookie-safe token use.``
  [bytes]
  # spork's encoder takes a string; os/cryptorand and every ffi output
  # buffer in this package are buffers, so the coercion lives here
  # rather than at each of the five call sites
  (def std (base64/encode (string bytes)))
  (def end
    (do (var i (length std))
        (while (and (> i 0) (= (chr "=") (std (dec i)))) (-- i))
        i))
  (string/replace-all "/" "_" (string/replace-all "+" "-" (string/slice std 0 end))))

(defn base64url-decode
  ``Decode base64url, with or without padding. Throws on input that is
  not base64url — a token that does not decode is not a token, and
  the caller should not have to tell "invalid" from "empty".``
  [s]
  (def std (string/replace-all "_" "/" (string/replace-all "-" "+" (string s))))
  (def pad (% (length std) 4))
  (when (= 1 pad)
    (errorf "not base64url: %d characters is not a valid length" (length s)))
  (def padded (if (zero? pad) std (string std (string/repeat "=" (- 4 pad)))))
  (def [ok out] (protect (base64/decode padded)))
  (unless ok (errorf "not base64url: %q" s))
  out)

(defn base64
  ``Encode bytes as base64 with the standard alphabet and **no
  padding** — the spelling PHC password hashes use (`$scrypt$ln=14,
  r=8,p=1$<salt>$<hash>`). Padding is left off because the PHC string
  format says so, not because it is prettier: an `=` inside a
  `$`-separated field is what other stacks refuse to parse.``
  [bytes]
  (def std (base64/encode (string bytes)))
  (var i (length std))
  (while (and (> i 0) (= (chr "=") (std (dec i)))) (-- i))
  (string/slice std 0 i))

(defn base64-decode
  "Decode standard-alphabet base64, with or without padding."
  [s]
  (def text (string s))
  (def pad (% (length text) 4))
  (when (= 1 pad)
    (errorf "not base64: %d characters is not a valid length" (length text)))
  (def padded (if (zero? pad) text (string text (string/repeat "=" (- 4 pad)))))
  (def [ok out] (protect (base64/decode padded)))
  (unless ok (errorf "not base64: %q" s))
  out)

(defn hex
  "Bytes as lowercase hex — for hashes in logs, tokens in the database
  and everything a human has to compare by eye."
  [bytes]
  (def out (buffer/new (* 2 (length bytes))))
  (each b bytes (buffer/format out "%02x" b))
  (string out))

(defn unhex
  "Hex back to bytes; throws on anything that is not an even-length
  string of hex digits."
  [s]
  (unless (even? (length s))
    (errorf "not hex: %d characters" (length s)))
  (def out (buffer/new (div (length s) 2)))
  (var i 0)
  (while (< i (length s))
    (def pair (string/slice s i (+ i 2)))
    (def v (scan-number (string "0x" pair)))
    (unless (and (number? v) (int? v))
      (errorf "not hex: %q" pair))
    (buffer/push-byte out v)
    (+= i 2))
  (string out))
