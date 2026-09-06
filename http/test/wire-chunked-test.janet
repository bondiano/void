### The chunked decoder, fed every way a socket can split a body.
###
### The decoder is pure, so the whole test is a table: each stream is
### pushed into a buffer in pieces of every size from one byte up to
### the whole thing, and every split must decode to the same body, end
### at the same position and fail for the same reason. A reader that
### only ever saw whole chunks was the bug class both copies it replaced
### were open to.

(import ../test-support/paths)
(import void/http/wire :as wire)

# -- driving the decoder over a split stream -----------------------------

(defn- decode-split
  "Feed `raw` into a fresh buffer `piece` bytes at a time, calling the
  decoder whenever it asked for more (or at the start). Returns
  [final-state body calls] where calls counts decoder invocations."
  [raw piece &opt limits start]
  (default start 0)
  (def buf (buffer/new (length raw)))
  (def body @"")
  (var st (wire/chunked-start start))
  (var calls 0)
  (var i 0)
  (defn decode! []
    (++ calls)
    (set st (wire/decode-chunked buf st limits))
    (buffer/push body (st :out)))
  (decode!)
  (while (and (< i (length raw)) (st :need))
    (def end (min (length raw) (+ i piece)))
    (buffer/push buf (string/slice raw i end))
    (set i end)
    # only call again once the decoder's ask is met, the way a loop
    # around a socket read would
    (when (>= (length buf) (st :need))
      (decode!)))
  [st (string body) calls])

(defn- every-split
  "Every piece size from 1 to the whole stream."
  [raw]
  (range 1 (inc (length raw))))

(defn- check-all-splits
  "Decode `raw` at every split and assert each outcome matches `expect`:
  `:phase`, and `:body`/`:pos` or `:reason` as given."
  [label raw expect &opt limits]
  (each piece (every-split raw)
    (def [st body _] (decode-split raw piece limits))
    (def where (string/format "%s (pieces of %d)" label piece))
    (assert (= (expect :phase) (st :phase))
            (string/format "%s: phase %q, wanted %q" where (st :phase) (expect :phase)))
    (when-let [b (expect :body)]
      (assert (= b body) (string/format "%s: body %q" where body)))
    (when-let [p (expect :pos)]
      (assert (= p (st :pos)) (string/format "%s: pos %d, wanted %d" where (st :pos) p)))
    (when-let [r (expect :reason)]
      (assert (= r (st :reason))
              (string/format "%s: reason %q, wanted %q" where (st :reason) r))
      (assert (= (wire/chunked-reasons r) (st :message))
              (string/format "%s: the message is the reason's sentence" where)))))

# -- well-formed bodies --------------------------------------------------

(def plain "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
(check-all-splits "two chunks" plain
                  {:phase :done :body "hello world" :pos (length plain)})

(def with-ext "5;ext=1;other\r\nhello\r\n0\r\n\r\n")
(check-all-splits "chunk extensions are skipped" with-ext
                  {:phase :done :body "hello" :pos (length with-ext)})

(def with-trailers "3\r\nabc\r\n0\r\nx-checksum: 1\r\nx-other: two\r\n\r\n")
(check-all-splits "trailers are consumed" with-trailers
                  {:phase :done :body "abc" :pos (length with-trailers)})

(def empty-body "0\r\n\r\n")
(check-all-splits "an empty body is the terminator alone" empty-body
                  {:phase :done :body "" :pos 5})

(def hex-case "A\r\n0123456789\r\na\r\n0123456789\r\n0\r\n\r\n")
(check-all-splits "hex sizes in either case" hex-case
                  {:phase :done :body "01234567890123456789" :pos (length hex-case)})

# leftover bytes after the terminator are the next request/response on
# the connection: :pos stops exactly at the terminator
(def pipelined (string plain "GET / HTTP/1.1\r\n"))
(check-all-splits "pipelined bytes are left alone" pipelined
                  {:phase :done :body "hello world" :pos (length plain)})

# the body may start anywhere — just past a head, in practice
(let [[st body _] (decode-split (string "HEAD\r\n\r\n" plain) 5 nil 8)]
  (assert (= :done (st :phase)))
  (assert (= "hello world" body) "decoding starts at `start`, not at 0")
  (assert (= (+ 8 (length plain)) (st :pos))))

# -- the reads that straddle a boundary ----------------------------------

# a chunk whose data arrives in several reads is emitted as it comes:
# every call's :out is a prefix-free piece and their concatenation is
# the chunk
(let [[st body calls] (decode-split "b\r\nhello world\r\n0\r\n\r\n" 4)]
  (assert (= "hello world" body))
  (assert (> calls 2) "the decoder was resumed more than once"))

# -- limits: the same reason on both sides -------------------------------

(check-all-splits "a chunk announcing past max-body" plain
                  {:phase :error :reason :too-large} {:max-body 10})
(check-all-splits "the total past max-body" plain
                  {:phase :error :reason :too-large} {:max-body 7})
(check-all-splits "exactly max-body is allowed" plain
                  {:phase :done :body "hello world"} {:max-body 11})

# the limit is checked at the size line: a 2 GB announcement fails
# before a byte of it is read
(let [[st _ _] (decode-split "7FFFFFFF\r\n" 100 {:max-body 1048576})]
  (assert (= :too-large (st :reason)) "refused at the announcement"))

# :max-line bounds what may pile up *without a line ending* — a peer
# dripping hex digits forever — which is what both readers guarded
(def long-line (string/repeat "1" 40))
(check-all-splits "a chunk-size line past max-line" long-line
                  {:phase :error :reason :oversized-line} {:max-line 16})
(check-all-splits "a chunk-size line under max-line is still just incomplete"
                  "1;" {:phase :size} {:max-line 16})

(def long-trailers (string "0\r\n" (string/repeat "x-h: v\r\n" 8)))
(check-all-splits "trailers past max-line" long-trailers
                  {:phase :error :reason :oversized-trailers} {:max-line 16})
(check-all-splits "no max-line means unbounded lines" long-line
                  {:phase :size} {})

# -- malformed framing ---------------------------------------------------

(check-all-splits "a size that is not hex" "zz\r\nab\r\n0\r\n\r\n"
                  {:phase :error :reason :malformed})
(check-all-splits "an empty size line" "\r\nab\r\n0\r\n\r\n"
                  {:phase :error :reason :malformed})
(check-all-splits "a chunk not closed by CRLF" "3\r\nabcXX0\r\n\r\n"
                  {:phase :error :reason :bad-terminator})
(check-all-splits "a chunk closed by a bare LF" "3\r\nabc\n\r\n0\r\n\r\n"
                  {:phase :error :reason :bad-terminator})

# -- the ask is honest ---------------------------------------------------

# :need is the smallest buffer length that lets the decoder go on: an
# incomplete chunk asks for at least one more byte, a chunk whose data
# is in but whose CRLF is not asks for exactly the two
(def st0 (wire/decode-chunked @"5\r\nhel" (wire/chunked-start 0)))
(assert (= 7 (st0 :need)) "mid-chunk: one more byte")
(assert (= "hel" (st0 :out)) "and what arrived is already out")
(def st1 (wire/decode-chunked @"5\r\nhello" st0))
(assert (= 10 (st1 :need)) "data complete: the two CRLF bytes")
(assert (= "lo" (st1 :out)))
(def st2 (wire/decode-chunked @"5\r\nhello\r\n" st1))
(assert (= 11 (st2 :need)) "at a size line: anything more")
(assert (= "" (st2 :out)) "no data, nothing out")
(assert (nil? (st2 :remaining)) "a finished chunk leaves no remainder behind")

# a state is a value: decoding twice from the same one gives the same
# answer and leaves the first untouched
(def buf @"5\r\nhello\r\n0\r\n\r\n")
(def a (wire/decode-chunked buf (wire/chunked-start 0)))
(def b (wire/decode-chunked buf (wire/chunked-start 0)))
(assert (deep= a b) "the decoder is a function of (buf state)")
(assert (struct? a) "states are frozen")
(assert (= "5\r\nhello\r\n0\r\n\r\n" (string buf)) "buf is never consumed")

# -- read-chunked: the caller's I/O, not the decoder's -------------------

(defn- feeder
  "A `want` that appends `raw` to buf `piece` bytes at a time until
  buf is at least n long, or throws `at-eof` when raw runs out —
  what a socket read loop does, without the socket."
  [buf raw piece at-eof]
  (var i 0)
  (fn want [n]
    (while (< (length buf) n)
      (when (>= i (length raw)) (error at-eof))
      (def end (min (length raw) (+ i piece)))
      (buffer/push buf (string/slice raw i end))
      (set i end))))

(each piece [1 2 3 7 (length with-trailers)]
  (def buf @"")
  (def st (wire/read-chunked buf 0 {:max-body 100}
                             (feeder buf with-trailers piece :eof)))
  (assert (= :done (st :phase)))
  (assert (= "abc" (st :body)) (string/format "read-chunked, pieces of %d" piece))
  (assert (= (length with-trailers) (st :pos))))

# what `want` throws is what the caller sees — the decoder never
# raises, so a short read is the caller's error in the caller's shape
(let [buf @""
      [ok err] (protect (wire/read-chunked buf 0 {} (feeder buf "5\r\nhel" 2 {:my :eof})))]
  (assert (not ok))
  (assert (deep= {:my :eof} err) "a short read surfaces as the caller's own error"))

# an error state comes back as a value, with the body decoded so far
(let [buf @""
      st (wire/read-chunked buf 0 {:max-body 3} (feeder buf plain 4 :eof))]
  (assert (= :error (st :phase)))
  (assert (= :too-large (st :reason)))
  (assert (= "" (st :body))))

(print "wire-chunked-test: all assertions passed")
