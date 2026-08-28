(import ../test-support/paths)
(import void/security/ip :as ip)

# -- CIDRs ---------------------------------------------------------------

(assert (deep= {:bits 8 :bytes [10 0 0 0]} (ip/parse-cidr "10.0.0.0/8")))
(assert (= 32 ((ip/parse-cidr "192.168.1.1") :bits)) "a bare address is a /32")
(assert (= 16 (length ((ip/parse-cidr "::1") :bytes))) "IPv6 expands to sixteen bytes")

(assert (ip/in-cidr? "10.1.2.3" (ip/parse-cidr "10.0.0.0/8")))
(assert (not (ip/in-cidr? "11.1.2.3" (ip/parse-cidr "10.0.0.0/8"))))
(assert (ip/in-cidr? "192.168.1.7" (ip/parse-cidr "192.168.1.0/24")))
(assert (not (ip/in-cidr? "192.168.2.7" (ip/parse-cidr "192.168.1.0/24"))))
(assert (ip/in-cidr? "10.1.2.3" (ip/parse-cidr "0.0.0.0/0")) "a /0 matches everything")
(assert (ip/in-cidr? "2001:db8::5" (ip/parse-cidr "2001:db8::/32")))
(assert (not (ip/in-cidr? "2001:db9::5" (ip/parse-cidr "2001:db8::/32"))))
(assert (not (ip/in-cidr? "10.1.2.3" (ip/parse-cidr "::/0")))
        "an IPv4 address is not inside an IPv6 range")
(assert (not (ip/in-cidr? "not-an-address" (ip/parse-cidr "10.0.0.0/8")))
        "and nonsense is simply not in it, rather than an error on the hot path")

(each bad ["300.1.2.3" "1.2.3" "10.0.0.0/x" "::gg"]
  (def [ok] (protect (ip/parse-cidr bad)))
  (assert (not ok) (string/format "%q is not a CIDR" bad)))

# -- the client address --------------------------------------------------

(defn- req [peer xff]
  @{:headers (if xff @{"x-forwarded-for" xff} @{})
    :void.security/peer peer})

(def none {:trusted-proxies [] :forwarded-header "x-forwarded-for"})
(assert (= "198.51.100.7" (ip/client-ip (req "198.51.100.7" nil) none)))
(assert (= "198.51.100.7" (ip/client-ip (req "198.51.100.7" "1.2.3.4") none))
        "with no trusted proxies the header is ignored entirely — otherwise a limit is a header away from being someone else's")

(def behind {:trusted-proxies ["10.0.0.0/8"] :forwarded-header "x-forwarded-for"})
(assert (= "203.0.113.7" (ip/client-ip (req "10.0.0.9" "203.0.113.7") behind)))
(assert (= "203.0.113.7" (ip/client-ip (req "10.0.0.9" "203.0.113.7, 10.0.0.5") behind))
        "trusted hops on the right are skipped")
(assert (= "198.51.100.1"
           (ip/client-ip (req "10.0.0.9" "203.0.113.7, 198.51.100.1, 10.0.0.5") behind))
        "and the rightmost untrusted hop wins — everything left of it was chosen by the client")
(assert (= "10.0.0.9" (ip/client-ip (req "10.0.0.9" nil) behind))
        "a trusted peer with no header is still the peer")
(assert (= "198.51.100.2" (ip/client-ip (req "198.51.100.2" "1.2.3.4") behind))
        "a peer that is not a trusted proxy cannot have its header believed")

(assert (deep= ["a" "b"] (tuple ;(ip/forwarded-chain (req "1.1.1.1" "a, b") behind))))
(assert (empty? (ip/forwarded-chain (req "1.1.1.1" nil) behind)))

(assert (nil? (ip/client-ip @{:headers @{}} none))
        "no socket and no header is nil — the inject path, where a test sets the header instead")

(print "ip-test ok")
