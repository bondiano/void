### void/bus/codec — how a message becomes bytes and back (extension point :void.bus/codec).
###
### A backend that keeps messages anywhere but this process's heap
### keeps them as bytes, and which bytes is a contract between the
### publisher and every consumer there will ever be — including the
### one written in another language two years from now. That is what a
### codec names, and why `[:bus :codec]` is a deliberate line in a
### config rather than a default nobody read.
###
###   :json  the interchange answer, and the default. Keywords go out
###          as strings and **come back strings**, which is the trade:
###          a payload another service can read is worth more than a
###          keyword that survives a round trip, and a consumer that
###          wants keywords back says so with a schema (./cqrs)
###   :jdn   Janet data notation: keywords, nested structure and a
###          number that reads back a number. Round-trips everything
###          and is readable only by Janet — the right choice for a
###          monolith whose messages never leave it, and the wrong one
###          for anything a second language consumes
###   :raw   no encoding at all: the value is handed to the backend as
###          it is. Only an in-heap backend can accept it, and a
###          backend that stores bytes **refuses it at start** rather
###          than stringifying a table into something nobody can read
###          back
###
### **The codec runs on every backend, including the in-process one.**
### It would be cheaper not to: `:memory` could pass the table through
### and save an encode plus a decode per message. It would also mean
### that a handler receiving `{:id 42}` under `:memory` receives
### `{"id" 42}` under `:pg` — the payload shape would depend on the
### deployment, every test would be a test of a shape production does
### not have, and the failure would arrive in the one environment that
### has no test suite. So the round trip is symmetric by construction,
### and `:raw` is how an application that has read this paragraph buys
### the two allocations back.
###
### A decode failure throws. A message that is not what the codec
### expects is either corruption or two publishers disagreeing about
### the format, and both are worth an error at the seam rather than a
### nil three frames later.

(import spork/json)

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def raw
  ``No encoding: the value goes to the backend as it is. Usable only
  with a backend that keeps messages in this process's heap — see
  `check-compatible!`.``
  {:name :raw
   :bytes? false
   :doc "no encoding — the value is handed to the backend as it is (in-heap backends only)"
   :encode (fn raw-encode [v] v)
   :decode (fn raw-decode [v] v)})

(def jdn
  ``Janet data notation. Round-trips keywords, tables, structs, nested
  arrays and numbers; readable only by Janet, and read back with
  `parse`, which reads data and never evaluates it.``
  {:name :jdn
   :bytes? true
   :doc "Janet data notation — full fidelity, Janet only"
   :encode (fn jdn-encode [v] (string/format "%j" v))
   :decode (fn jdn-decode [v] (if (nil? v) nil (parse v)))})

(def json
  ``JSON, for messages another language also reads. Keyword keys go
  out as strings and come back as strings.``
  {:name :json
   :bytes? true
   :doc "JSON — the interchange format, and lossy about keywords"
   # `string`, not the buffer spork/json returns: a buffer is bound as
   # a *binary* parameter by void/db-postgres, and the JSON of a
   # message would land in a text column hex-escaped — readable by
   # nothing, including the consumer. Caught by running the same suite
   # on both engines (test/db-postgres-test.janet), which is what that
   # suite is for
   :encode (fn json-encode [v] (string (json/encode v)))
   :decode (fn json-decode [v] (if (nil? v) nil (json/decode v)))})

(def builtin
  "The codecs this plugin contributes to :void.bus/codec."
  [json jdn raw])

(defn normalize
  "Validate a codec contribution and fill in its defaults. Throws with
  the offending key named."
  [c]
  (unless (dictionary? c)
    (errorf "bus codec must be a dictionary, got %q" c))
  (def name (get c :name))
  (unless (keyword? name)
    (errorf "bus codec: :name must be a keyword, got %q" name))
  (each k [:encode :decode]
    (unless (callable? (get c k))
      (errorf "bus codec %q: %q must be a function, got %q" name k (get c k))))
  (table/to-struct (merge @{:bytes? true :doc nil} c)))

(defn find-codec
  ``The codec named by `name` among `codecs` (the resolved extension
  point), or an error listing what there is — a typo in [:bus :codec]
  must not fall back to publishing something else.``
  [codecs name]
  (or (get codecs name)
      (errorf "unknown bus codec %q (contributed: %s)"
              name
              (string/join (map |(string/format "%q" $) (sorted (keys codecs))) " "))))

(defn check-compatible!
  ``Refuse a codec the backend cannot store. Only `:raw` can be wrong
  here, and only against a backend that keeps bytes: the error names
  both sides and the one-line fix, because the alternative is a
  `%q`-stringified table in a column and a decode failure on the
  consumer, in production, at the first message.``
  [codec backend]
  (when (and (get backend :encoded?) (not (get codec :bytes?)))
    (errorf "the %q bus backend stores messages as bytes and the %q codec does not produce any — set [:bus :codec] to :json (interchange) or :jdn (Janet only)"
            (get backend :name) (get codec :name)))
  true)

(defn encode-body
  ``Encode the part of a message that travels as an opaque body — the
  payload — with `codec`. The id, the topic and the meta are *not* in
  here: a backend that has columns puts them in columns, and a
  correlation id that can only be read by decoding the payload is a
  correlation id no operator will ever use in a WHERE clause.``
  [codec payload]
  ((codec :encode) payload))

(defn decode-body
  "Decode a payload with `codec`. nil stays nil: a message with no
  payload is a fact, not a thing to decode."
  [codec body]
  (if (nil? body) nil ((codec :decode) body)))

(defn encode-meta
  ``Encode a message's meta. Always the same codec as the payload —
  two formats in one row would be two things to explain to whoever
  reads the table without void.``
  [codec meta]
  ((codec :encode) (or meta {})))

(defn decode-meta
  "Decode a message's meta back into a table, keyword-keyed. JSON
  hands back string keys, and meta is the one part of a message void
  itself reads, so the framework's own keys are put back the way the
  framework wrote them — an application's extra keys keep whatever
  shape the codec gave them."
  [codec body]
  (def raw-meta (if (nil? body) {} ((codec :decode) body)))
  (def out @{})
  (eachp [k v] (or raw-meta {})
    (put out (if (keyword? k) k (keyword k)) v))
  out)
