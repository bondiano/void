### void/redis/codec — how a Janet value becomes bytes and back
### (extension point :void.redis/codec).
###
### Redis stores byte strings. Everything else — a table, a keyword, a
### number that must come back a number — is a convention between the
### writer and the reader, and the convention is what a codec names.
### `[:redis :codec]` picks the one the value-carrying commands
### (`get`/`set`, the cache surface, hash values) run through; a plugin
### adds another by contributing to :void.redis/codec.
###
### The default is `:raw` — bytes in, bytes out — because that is what
### makes this client interoperable: a key another service wrote is
### readable, and a key written here is readable by redis-cli. A codec
### is opt-in precisely because it is a claim about who else reads the
### data.
###
###   :raw   strings and numbers as they are; what comes back is the
###          string redis holds
###   :jdn   Janet data notation: tables, keywords, nested structure,
###          and a number that reads back as a number. Janet-only, and
###          the session store's choice for exactly that reason —
###          a session is a Janet table with keyword keys, and no
###          interchange format keeps both halves of that
###   :json    the interchange answer; keys come back strings, which is
###          the trade being made
###
### A decode failure is left to throw: a value that is not what the
### codec expects is corruption or a collision between two writers,
### and both are worth an error rather than a nil.

(import spork/json)
(import ./resp :as resp)

(def raw
  ``Bytes as bytes: the value goes to the server the way a command
  argument does, and comes back the string redis is holding.``
  {:name :raw
   :encode (fn raw-encode [v] (resp/argument v))
   :decode (fn raw-decode [v] v)})

(def jdn
  ``Janet data notation. Round-trips tables, structs, keywords, nested
  arrays and numbers; readable only by Janet, and by `parse`, which
  reads data and never evaluates it.``
  {:name :jdn
   :encode (fn jdn-encode [v] (string/format "%j" v))
   :decode (fn jdn-decode [v] (if (nil? v) nil (parse v)))})

(def json
  ``JSON, for values another language also reads. Keywords go out as
  strings and come back as strings — a fact worth knowing before
  storing a table keyed by keywords.``
  {:name :json
   :encode (fn json-encode [v] (json/encode v))
   :decode (fn json-decode [v] (if (nil? v) nil (json/decode v)))})

(def builtin
  "The codecs this plugin contributes to :void.redis/codec."
  [raw jdn json])

(defn find-codec
  ``The codec named by `name` among `codecs` (the resolved extension
  point), or an error listing what there is — a typo in
  [:redis :codec] should not fall back to storing something else.``
  [codecs name]
  (or (get codecs name)
      (errorf "unknown redis codec %q (contributed: %s)"
              name
              (string/join (map |(string/format "%q" $) (sorted (keys codecs))) " "))))

(defn encode
  "Encode one value with a codec."
  [codec v]
  ((codec :encode) v))

(defn decode
  ``Decode one reply with a codec. A nil reply (the key does not
  exist) stays nil in every codec: absence is not a value to decode.``
  [codec v]
  (if (nil? v) nil ((codec :decode) v)))

(defn decode-all
  "Decode an array of replies — what MGET and the list commands
  answer with."
  [codec vs]
  (when vs (map |(decode codec $) vs)))
