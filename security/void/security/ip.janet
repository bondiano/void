### void/security/ip — the client address, computed rather than believed.
###
### `X-Forwarded-For` is user input until proven otherwise: anybody can
### send one, and a rate limiter that keys on it limits whoever the
### attacker chose to name. The only thing that makes a hop credible is
### that the *previous* hop is a proxy we put there, so
### `[:security :trusted-proxies]` is a list of CIDRs and `client-ip`
### walks the header from the right, skipping trusted hops, and stops
### at the first address that is not one.
###
### The default list is **empty**, and that is the safe direction: with
### no configuration the answer is the socket peer, which behind nginx
### means every request looks like it comes from the proxy — visible,
### annoying, fixed by one line. The opposite default would mean a
### limit anybody can step around with a header, and nobody would ever
### notice.
###
### The peer address is the request's `:remote-addr` — read off the
### socket once per connection by the server, given in the spec on the
### inject path — so a test that sets a peer and a header is exactly
### the test that works without a socket.

(def defaults
  "Defaults of the address half of the [:security] slice."
  {:trusted-proxies []
   :forwarded-header "x-forwarded-for"})

(defn parse-cidr
  ``Parse "10.0.0.0/8" (or a bare address) into {:bytes :bits}. IPv4
  and IPv6 both, because a deployment behind a v6 proxy is not
  exotic.``
  [text]
  (def s (string text))
  (def i (first (string/find-all "/" s)))
  (def addr (if i (string/slice s 0 i) s))
  (def bits (when i (scan-number (string/slice s (inc i)))))
  (def parts
    (if (string/find ":" addr)
      # v6: expand the :: shorthand into 16 bytes
      (let [[head tail] (let [j (string/find "::" addr)]
                          (if j
                            [(string/slice addr 0 j) (string/slice addr (+ j 2))]
                            [addr nil]))
            group (fn [text]
                    (if (or (nil? text) (empty? text))
                      @[]
                      (seq [g :in (string/split ":" text)
                            :let [n (scan-number (string "0x" g))]]
                        (do (unless n (errorf "not an IPv6 group: %q" g))
                            n))))
            hs (group head)
            ts (group tail)
            fill (- 8 (+ (length hs) (length ts)))]
        (when (neg? fill) (errorf "not an IPv6 address: %q" addr))
        (def out @[])
        (each g hs (array/push out (brshift g 8)) (array/push out (band g 0xff)))
        (for _ 0 fill (array/push out 0) (array/push out 0))
        (each g ts (array/push out (brshift g 8)) (array/push out (band g 0xff)))
        out)
      (let [groups (string/split "." addr)]
        (unless (= 4 (length groups)) (errorf "not an IPv4 address: %q" addr))
        (seq [g :in groups :let [n (scan-number g)]]
          (do (unless (and n (int? n) (<= 0 n 255)) (errorf "not an IPv4 address: %q" addr))
              n)))))
  (def width (* 8 (length parts)))
  # a `/` with a prefix that does not parse is a typo, and silently
  # treating it as a host route turns "trust this network" into "trust
  # this one address" without a word
  (when (and i (not (and bits (int? bits) (<= 0 bits width))))
    (errorf "not a CIDR prefix: %q (0..%d)" (string/slice s (inc i)) width))
  {:bytes (tuple ;parts)
   :bits (or bits width)})

(defn in-cidr?
  "Is `address` inside `cidr` (as parsed by `parse-cidr`)?"
  [address cidr]
  (def [ok parsed] (protect (parse-cidr address)))
  (and ok
       (= (length (parsed :bytes)) (length (cidr :bytes)))
       (do
         (var same true)
         (var left (cidr :bits))
         (var i 0)
         (while (and same (pos? left))
           (def mask (if (>= left 8) 0xff (band 0xff (blshift 0xff (- 8 left)))))
           (unless (= (band mask (in (parsed :bytes) i))
                      (band mask (in (cidr :bytes) i)))
             (set same false))
           (-= left (min 8 left))
           (++ i))
         same)))

(defn peer-address
  ``The peer of a request: `:remote-addr`, which the server reads off
  the socket once per connection and the inject path takes from its
  spec. A test may also plant `:void.security/peer` directly. nil when
  there is none — which is why every rule below treats a missing peer
  as "no trusted hop" rather than as an error.``
  [req]
  (if (in req :void.security/peer)
    (get req :void.security/peer)
    (get req :remote-addr)))

(defn forwarded-chain
  "The X-Forwarded-For chain of a request, left to right, trimmed."
  [req &opt cfg]
  (default cfg defaults)
  (def raw (get-in req [:headers (get cfg :forwarded-header "x-forwarded-for")]))
  (def value (if (indexed? raw) (string/join raw ", ") raw))
  (if (or (nil? value) (empty? (string value)))
    []
    (map string/trim (string/split "," (string value)))))

(defn trusted?
  "Is this address one of the configured proxies?"
  [address cfg]
  (truthy?
    (when address
      (some (fn [c]
              (def [ok cidr] (protect (parse-cidr c)))
              (and ok (in-cidr? address cidr)))
            (get cfg :trusted-proxies [])))))

(defn client-ip
  ``The address to attribute this request to.

  Without trusted proxies: the socket peer, and the header is ignored
  entirely. With them: the rightmost address in `X-Forwarded-For` that
  is not itself a trusted proxy — the last hop we did not put there,
  and therefore the last one that could not have been chosen by the
  client.``
  [req &opt cfg]
  (default cfg defaults)
  (def peer (peer-address req))
  (if-not (trusted? peer cfg)
    peer
    (do
      (def chain (forwarded-chain req cfg))
      (var found nil)
      (loop [i :down-to [(dec (length chain)) 0] :while (nil? found)]
        (def candidate (in chain i))
        (unless (trusted? candidate cfg)
          (set found candidate)))
      (or found peer))))
