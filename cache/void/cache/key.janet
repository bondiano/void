### void/cache/key — what a cache key is.
###
### A cache key has to be two things at once, and they pull in
### different directions. It has to be *readable*, because the key is
### what you type into redis-cli at three in the morning; and it has to
### be *deterministic and injective*, because a key derived from a call
### is only useful if the same call builds the same key in every
### process and a different call never builds the same one.
###
### So there are two spellings. A key the application writes itself —
### a string, a keyword — is used verbatim: `(cache/get "rates:usd")`
### reaches redis as `rates:usd` and nothing else. A key *derived* from
### values — the arguments of a `wrap`ped function, a composite key —
### goes through `canonical`, a tagged, length-prefixed rendering that
### is injective by construction and sorts dictionary pairs so two
### tables with the same contents render the same way. That last part
### is the whole reason this module exists rather than a call to
### `%j`: Janet prints dictionary keys in hash order, which is stable
### within one process and nothing more, and a cache shared between
### processes that key their entries differently is a cache with a
### 0% hit rate and no error message.
###
### What cannot be a key is a function, a fiber or an abstract type.
### Rendering one by identity would key on an address — a cache that
### misses forever, or worse, hits on a recycled one — so it is an
### error with the value in the message.

(defn- render [out v]
  (cond
    (nil? v) (buffer/push out "n")
    (true? v) (buffer/push out "T")
    (false? v) (buffer/push out "F")
    # every Janet number is a double, so (string 1.0) and (string 1)
    # are the same text — which is right: they are the same value
    (number? v) (buffer/format out "#%s;" (string v))
    (or (string? v) (buffer? v)) (buffer/format out "s%d:%s" (length v) v)
    (keyword? v) (buffer/format out "k%d:%s" (length v) v)
    (symbol? v) (buffer/format out "y%d:%s" (length v) v)

    (indexed? v)
    (do (buffer/push out "[")
        (each x v (render out x))
        (buffer/push out "]"))

    (dictionary? v)
    (do (buffer/push out "{")
        # sorted by the rendering of the key, not by the key: it is a
        # total order over every kind of key a table can have, and it
        # is the same order in every process
        (each [rk value] (sorted-by first (seq [[k value] :pairs v]
                                            [(string (render @"" k)) value]))
          (buffer/push out rk)
          (render out value))
        (buffer/push out "}"))

    (errorf "cannot build a cache key from %q — a key is built out of data, and %s has no value-level identity"
            v (type v)))
  out)

(defn canonical
  ``A deterministic, injective rendering of a cacheable value: the same
  value renders the same way in every process and no two different
  values render the same way.

      (canonical [:user 42])   # => "[k4:user#42;]"
      (canonical {:b 1 :a 2})  # => "{k1:a#2;k1:b#1;}" — sorted

  Numbers, booleans, nil, strings, buffers, keywords, symbols and any
  nesting of arrays/tuples/tables/structs are renderable; a function,
  a fiber or an abstract value is an error.``
  [v]
  (string (render (buffer/new 32) v)))

(defn cache-key
  ``A key as the store sees it. The spellings a key is *written* in —
  bytes, keywords, symbols, numbers — are used verbatim, so
  `(cache-key :rates)` is `"rates"` and `(cache-key 42)` is `"42"`,
  which is what makes a key you wrote a key you can find in a
  keyspace. Anything composite is `canonical`.

  Two collisions this leaves are deliberate. `42` and `"42"` are one
  key, which is the answer anybody would want from a cache. And a
  string that happens to spell out a canonical rendering collides with
  the value that renders to it — writing `"[k4:user#42;]"` as a
  literal key is not something that happens by accident.``
  [k]
  (cond
    (string? k) k
    (buffer? k) (string k)
    (keyword? k) (string k)
    (symbol? k) (string k)
    (number? k) (string k)
    (canonical k)))

(defn for-call
  ``The key a memoized call is stored under: the name, then the
  argument tuple rendered canonically.

      (for-call :rates ["usd" 2])   # => "rates[s3:usd#2;]"

  Keys are as long as the arguments make them — nothing here hashes or
  truncates, because a truncated key is a key that collides, and a
  cache that answers the wrong question is worse than no cache. A
  function called with big arguments wants `wrap`'s :key option.``
  [name args]
  (string (cache-key name) (canonical (tuple ;args))))
