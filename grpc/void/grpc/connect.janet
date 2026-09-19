### void/grpc/connect — the Connect protocol, unary, over HTTP/1.1.
###
### Connect is what lets void speak to the gRPC ecosystem without
### HTTP/2. A unary call is one POST:
###
###     POST /shop.orders.OrderService/GetOrder
###     Content-Type: application/proto
###     Connect-Protocol-Version: 1
###
###     <the encoded request message>
###
### and the answer is the encoded response with status 200, or an error
### with the status its code maps to and a JSON body naming it. There are
### no length prefixes, no trailers to parse and no frames: the body *is*
### the message. That is the whole reason this protocol exists, and the
### reason it fits on a server that has HTTP/1.1 and intends to keep it.
###
### **Streaming is not here, and does not pretend to be.** Connect's
### streaming variants use the same envelope machinery gRPC does and
### need a transport that can keep two directions open; that puts
### that in v2 with its own decision. A `.proto` that declares a
### `stream` is refused when the service is *declared*, not when a
### client calls it — the failure belongs where somebody can fix it.
###
### **GET, for the methods that said they are safe.** Connect defines
### a GET form for methods marked `idempotency_level =
### NO_SIDE_EFFECTS`, with the message in the query string. void
### serves it, and that is not a nicety: a GET is what a cache
### understands, so `:void.cache/response` route metadata works on an
### RPC method exactly as it works on a page.
###
### **No compression.** `identity` and nothing else — void has no
### compressor (the same sentence void/ws says about
### permessage-deflate), so a request that arrives gzipped is answered
### `unimplemented` with the encodings this server accepts, rather
### than with a decode failure that reads like corruption.

(import spork/json)
(import spork/base64)
(import void/http/ring :as ring)
(import ./codes :as codes)

(def protocol-version
  "The value of Connect-Protocol-Version this server speaks."
  "1")

(def response-key
  "What `respond` marks a response with, so a handler can carry
  headers without returning an HTTP response."
  :void.grpc/response)

(defn respond
  {:params [:any (or {:headers (or @{:string :string} :nil) :trailers (or @{:string :string} :nil) & r} :nil)]
   :ret @{:void.grpc/response :boolean :message :any :headers @{:string :string}
          :trailers @{:string :string}}}
  ``A response message plus metadata, for a handler that has something
  to say besides the message:

      (grpc/respond order {:headers {"x-cache" "miss"}
                           :trailers {"x-rows-read" "12"}})

  Connect carries a unary call's trailers as `Trailer-`-prefixed
  headers, which is what a client reads them back out of.``
  [message &opt opts]
  (default opts {})
  @{response-key true
    :message message
    :headers (get opts :headers {})
    :trailers (get opts :trailers {})})

(defn response?
  {:params [:any] :ret :boolean :narrows {:void.grpc/response :boolean :message :any & r}}
  "Is this a `respond` value rather than a bare message?"
  [v]
  (and (dictionary? v) (v response-key)))

# -- codecs --------------------------------------------------------------

(defn- normalize-ct
  {:params [:any] :ret :string}
  "A content type, lower-cased and its `;` parameters stripped, so
  \"application/json; charset=utf-8\" compares equal to \"application/json\"."
  [ct]
  (def s (string/ascii-lower (string (or ct ""))))
  (string/trim (if-let [semi (string/find ";" s)] (string/slice s 0 semi) s)))

(defn codec-for
  {:params [(or [{:name :keyword :content-type :string :encoding :string
                 :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                 :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r}]
                @[{:name :keyword :content-type :string :encoding :string
                  :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                  :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r}])
            :any]
   :ret (or :nil {:name :keyword :content-type :string :encoding :string
                  :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                  :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r})}
  ``The codec a content type selects, or nil. `codecs` is the resolved
  :void.grpc/codec point — a list, in contribution order, and the
  first match wins.``
  [codecs ct]
  (def want (normalize-ct ct))
  (find (fn [c]
          (or (= want (normalize-ct (c :content-type)))
              (some |(= want (normalize-ct $)) (get c :aliases []))))
        codecs))

(defn codec-by-name
  {:params [(or [{:name :keyword :content-type :string :encoding :string
                 :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                 :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r}]
                @[{:name :keyword :content-type :string :encoding :string
                  :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                  :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r}])
            :any]
   :ret (or :nil {:name :keyword :content-type :string :encoding :string
                  :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                  :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r})}
  "The codec whose Connect `encoding` name this is (`json`, `proto`)."
  [codecs name]
  (def want (string/ascii-lower (string (or name ""))))
  (find (fn [c] (or (= want (string (c :encoding)))
                    (some |(= want (string $)) (get c :encoding-aliases []))))
        codecs))

(defn content-types
  {:params [(or [{:content-type :string & r}] @[{:content-type :string & r}])] :ret @[:string]}
  "Every content type this server will accept a call in — what a 415
  lists."
  [codecs]
  (sorted (distinct (map |($ :content-type) codecs))))

# -- reading a call ------------------------------------------------------

(defn- base64url-decode
  {:params [:any] :ret :string}
  "Connect's GET form uses the URL-safe alphabet without padding —
  swapped back and re-padded so `base64/decode` can read it."
  [s]
  # Connect's GET form uses the URL-safe alphabet without padding
  (def t (string/replace-all "_" "/" (string/replace-all "-" "+" (string s))))
  (def pad (% (length t) 4))
  (string t (case pad 2 "==" 3 "=" 0 "" "=")))

(defn timeout-of
  {:params [:any]
   :ret (or :nil :number)
   :throws [GrpcFailure]}
  ``The client's deadline in seconds, from `Connect-Timeout-Ms`, or
  nil. A header that is not a number is refused rather than ignored:
  a client that asked for a deadline and silently did not get one is
  worse off than one told its header is wrong.

  The Connect protocol's grammar for the header is
  "Timeout-Milliseconds → positive integer as ASCII string of at most
  10 digits" (connectrpc.com/docs/protocol, Unary Request), so a zero
  is refused like any other malformed value. It matters because the
  deadline underneath (void/core/deadline) reads a non-positive
  timeout as "no deadline": a `0` let through would run the handler
  unbounded, the opposite of what the client asked for, and the
  header is the client's to write.``
  [req]
  (when-let [raw (ring/request-header req "connect-timeout-ms")]
    (def text (string raw))
    # the grammar's own check first: `scan-number` would also read
    # "1e3", "0x10", "+5" and "5.0", none of which the protocol allows
    (def ms (when (peg/match '(* :d+ -1) text) (scan-number text)))
    (unless (and ms (pos? ms) (<= (length text) 10))
      (codes/fail! :invalid_argument
                   (string/format "Connect-Timeout-Ms must be a positive whole number of milliseconds (at most 10 digits), got %q"
                                  text)))
    (/ ms 1000)))

(defn check-protocol-version!
  {:params [:any :boolean]
   :ret :nil
   :throws [GrpcFailure]}
  ``Refuse a call whose `Connect-Protocol-Version` is not this one.
  Present-and-wrong is always refused; absent is refused only when
  `required?` — see [:grpc :require-protocol-version] for why that is
  a setting rather than a rule.``
  [req required?]
  (def given (ring/request-header req "connect-protocol-version"))
  (cond
    (nil? given)
    (when required?
      (codes/fail! :invalid_argument
                   (string "this endpoint requires the Connect-Protocol-Version header "
                           "([:grpc :require-protocol-version]); every Connect client sends it")))
    (not= (string given) protocol-version)
    (codes/fail! :invalid_argument
                 (string/format "unsupported Connect-Protocol-Version %q — this server speaks %q"
                                (string given) protocol-version))))

(defn check-encoding!
  {:params [:any]
   :ret :nil
   :throws [GrpcFailure]}
  ``Refuse a compressed request. The status is 415 rather than the 501
  the code would otherwise carry: the Connect protocol says a
  Content-Type or Content-Encoding the server does not recognise is an
  unsupported *media type*, and the code in the body still says
  `unimplemented`.``
  [req]
  (def enc (ring/request-header req "content-encoding"))
  (when (and enc (not= "identity" (string/ascii-lower (string enc))))
    (codes/fail! :unimplemented
                 (string/format "void/grpc reads `identity` and nothing else — %q is not a compression this server has"
                                (string enc))
                 {:http/status 415
                  :headers {"accept-encoding" "identity"}})))

(defn read-post
  {:params [{:body (or :string :nil) & r}
            (or [{:name :keyword :content-type :string :encoding :string
                 :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                 :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & cr}]
                @[{:name :keyword :content-type :string :encoding :string
                  :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                  :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & cr}])]
   :ret [{:name :keyword :content-type :string :encoding :string
         :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
         :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & cr}
        :string]
   :throws [GrpcFailure]}
  ``The [codec bytes] of a POST call, or an RPC failure. An
  unrecognised — or missing — content type is a 415 carrying the code
  `unimplemented`: the protocol calls it an unsupported media type,
  and the body still names which of the sixteen it was.``
  [req codecs]
  (def ct (ring/request-header req "content-type"))
  (def codec (codec-for codecs ct))
  (unless codec
    (codes/fail! :unimplemented
                 (if ct
                   (string/format "%q is not a codec this server has (it has %s)"
                                  (normalize-ct ct)
                                  (string/join (content-types codecs) " "))
                   (string/format "a Connect call needs a Content-Type naming its codec (%s)"
                                  (string/join (content-types codecs) " ")))
                 {:http/status 415}))
  [codec (string (or (req :body) ""))])

(defn read-get
  {:params [{:query (or @{:string :any} :nil) & r}
            (or [{:name :keyword :content-type :string :encoding :string
                 :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                 :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & cr}]
                @[{:name :keyword :content-type :string :encoding :string
                  :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
                  :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & cr}])]
   :ret [{:name :keyword :content-type :string :encoding :string
         :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
         :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & cr}
        :string]
   :throws [GrpcFailure]}
  ``The [codec bytes] of a GET call. Connect puts the message in the
  query string: `encoding` names the codec, `message` carries the
  value and `base64=1` says it is URL-safe base64 — which a binary
  codec always needs and a JSON one needs when the message has
  characters a URL would rather not.``
  [req codecs]
  (def query (or (req :query) {}))
  (def encoding (get query "encoding"))
  (unless encoding
    (codes/fail! :invalid_argument
                 "a Connect GET needs ?encoding= naming the codec its ?message= is in"))
  (def codec (codec-by-name codecs encoding))
  (unless codec
    (codes/fail! :unimplemented
                 (string/format "%q is not a codec this server has (it has %s)"
                                encoding
                                (string/join (sorted (map |(string ($ :encoding)) codecs)) " "))))
  # `connect=v1` is how the GET form names the protocol version, the
  # way the header does for a POST: present-and-wrong is refused,
  # absent is not (see check-protocol-version!)
  (when-let [version (get query "connect")]
    (unless (= "v1" version)
      (codes/fail! :invalid_argument
                   (string/format "unsupported Connect version %q in ?connect= — this server speaks \"v1\""
                                  version))))
  (def compression (get query "compression"))
  (when (and compression (not= "identity" compression))
    (codes/fail! :unimplemented
                 (string/format "void/grpc reads `identity` and nothing else — %q is not a compression this server has"
                                compression)))
  (def raw (get query "message" ""))
  (def b64? (or (= "1" (get query "base64")) (= "true" (get query "base64"))))
  [codec (if b64?
           (let [[ok out] (protect (base64/decode (base64url-decode raw)))]
             (unless ok (codes/fail! :invalid_argument "?message= is not URL-safe base64"))
             (string out))
           raw)])

(defn decode-message
  {:params [{:name :keyword :content-type :string :encoding :string
            :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
            :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r}
           :any :string]
   :ret :any
   :throws [GrpcFailure]}
  "Decode a call's bytes into a message, turning a codec's complaint
  into `invalid_argument` — which is what a body the server cannot
  read is."
  [codec message bytes]
  (def [ok value] (protect ((codec :decode) message bytes)))
  (unless ok
    (codes/fail! :invalid_argument
                 (string/format "the request message could not be read as %s: %s"
                                (codec :content-type)
                                (if (string? value) value (string/format "%q" value)))))
  value)

# -- writing an answer ---------------------------------------------------

(defn- trailer-headers
  {:params [(or @{:string :any} :nil)] :ret @{:string :string}}
  "Trailing metadata as `Trailer-`-prefixed header names, Connect's
  own way of carrying a unary call's trailers."
  [trailers]
  (tabseq [[k v] :pairs (or trailers {})]
    (let [name (string/ascii-lower (string k))]
      (if (string/has-prefix? "trailer-" name) name (string "trailer-" name)))
    (string v)))

(defn ok-response
  {:params [{:name :keyword :content-type :string :encoding :string
            :encode (fn [:any :any] :any) :decode (fn [:any :any] :any)
            :aliases (or [:string] :nil) :encoding-aliases (or [:string] :nil) & r}
           :any :any
           (or {:headers (or @{:string :any} :nil) :trailers (or @{:string :any} :nil) & mr} :nil)]
   :ret @{:status :number :headers @{:string :string} :body :string}
   :throws [GrpcFailure]}
  "The 200 an answered call goes out as."
  [codec message value &opt meta]
  (default meta {})
  (def [ok body] (protect ((codec :encode) message value)))
  (unless ok
    # a handler that returned something its own .proto cannot describe
    # is a bug here, not at the client — and it must not look like one
    (error (codes/error-value
             :internal
             (string/format "the response could not be written as %s: %s"
                            (codec :content-type)
                            (if (string? body) body (string/format "%q" body))))))
  @{:status 200
    :headers (merge @{"content-type" (codec :content-type)}
                    (tabseq [[k v] :pairs (get meta :headers {})]
                      (string/ascii-lower (string k)) (string v))
                    (trailer-headers (get meta :trailers {})))
    :body (string body)})

(defn error-body
  {:params [{:void.grpc/code :keyword :message (or :string :nil)
            :details (or [:any] :nil) & r}
           (fn [:any] :any)]
   :ret :buffer}
  ``A Connect error as JSON. The shape is the protocol's:

      {"code":"not_found","message":"no order A-1","details":[...]}

  `details` are `{:type "shop.orders.BadField" :value <message>}`
  entries, encoded with the descriptor the type names and carried as
  base64 — which is how a generated client gets a typed detail back.``
  [failure encode-detail]
  (def out @{"code" (string (failure codes/key))})
  (unless (empty? (string (get failure :message "")))
    (put out "message" (string (failure :message))))
  (when-let [details (get failure :details)]
    (unless (empty? details)
      (put out "details" (map encode-detail details))))
  (json/encode out))

(defn error-response
  {:params [{:void.grpc/code :keyword :http/status (or :number :nil)
            :headers (or @{:string :any} :nil) :message (or :string :nil)
            :details (or [:any] :nil) & r}
           (fn [:any] :any)]
   :ret @{:status :number :headers @{:string :string} :body :buffer}}
  "The response an RPC failure goes out as: the status its code maps
  to, and the JSON body naming it — whatever codec the call used,
  because an error a client cannot read is not an error message."
  [failure encode-detail]
  @{:status (get failure :http/status (codes/http-status (failure codes/key)))
    :headers (merge @{"content-type" "application/json; charset=utf-8"}
                    (tabseq [[k v] :pairs (get failure :headers {})]
                      (string/ascii-lower (string k)) (string v)))
    :body (error-body failure encode-detail)})
