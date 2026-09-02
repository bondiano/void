### void/notify-webhook — the notification as a signed POST (ADR-0040 §5).
###
### §9 of the SPEC names "webhook and bot hubs" as a niche void is for,
### and this is the half of it void owes: a notification leaves the
### process as one JSON document over `void/http/client` (with
### `void/tls` under it when the endpoint is https, ADR-0038). A bot —
### Telegram, Slack, a colleague's inbox robot — is either this channel
### pointed at a URL or twenty lines of an application's own channel;
### void ships no vendor.
###
###     {"id": "ntf_9f3c...", "key": "order/shipped", "at": 1756400000,
###      "title": "Your order shipped", "body": "...",
###      "url": "/orders/1042", "data": {"order": 1042}}
###
### **The endpoint is a value, not a subscription table.** `:to {:url
### "https://hooks.example.com/void"}` sends this notification there;
### `[:notify-webhook :url]` is where everything else goes. Fan-out to
### many endpoints is an application's loop over `notify/send`, because
### the moment void owns a subscription table it owns its migrations,
### its admin page and its retry accounting per subscriber — and that
### is a package, not a channel.
###
### **The signature is computed at delivery, not at projection.** A MAC
### over a timestamp minted before a queue would arrive outside every
### receiver's tolerance window, so what is projected is the body and
### what is signed is `<t>.<body>` on the fiber that actually POSTs:
###
###     X-Void-Signature: t=1756400000,v1=<hex hmac-sha256>
###
### The scheme is Stripe's, because the receiver is somebody else's
### code and the shape they have already implemented is worth more than
### one of ours. `[:notify-webhook :signing-key]` arms it; void/crypto is a
### *module* edge (the void/storage/sign pose), so a configured secret
### without `:void/crypto` in the composition is a boot error naming
### the plugin rather than a signature nobody ever verifies.
###
### **The status code decides whether there is a retry.** 2xx is
### delivered. 4xx is the receiver's final answer — a wrong URL or a
### rejected signature is not fixed by five more attempts — except 408
### and 429, which say "later" in as many words. Everything else, 5xx
### and a broken connection included, is thrown for the queue.

(import spork/json)
(import void/core/config :as config)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/crypto :as crypto)
(import void/http/client :as client)
(import ./channel :as channel)
(import ./notification :as notification)

(require "void/notify/init")

(def log-ns "void.notify.webhook")

(def Config
  "Schema of the [:notify-webhook] config slice."
  {:url [:optional :string]
   :signing-key [:optional :any]
   :timeout [:optional [:number {:min 0.001}]]
   :headers [:optional :dictionary]
   :allow-hosts [:optional [:vector :string]]
   :allow-private [:optional :boolean]})

(def defaults
  ``Defaults of the [:notify-webhook] slice.

  There is no default `:url`: a webhook channel with a made-up endpoint
  would deliver every notification to nowhere in particular. Without
  one, only the notifications that carry `:to {:url ...}` go out, and
  the rest are `:skipped`.

  `:allow-hosts` and `:allow-private` govern where a *per-notification*
  URL may point (see `target-refusal`); the configured `:url` is the
  operator's own value and is not filtered. The default — no allowed
  hosts, no private addresses — is the safe direction: a notification
  cannot aim a POST at loopback, a private network or the cloud
  metadata address unless the deployment said so.``
  {:url nil
   :signing-key nil
   :timeout 10
   :headers {}
   :allow-hosts []
   :allow-private false})

(var settings
  "The [:notify-webhook] slice, resolved at :before-start."
  defaults)

# -- the wire format -----------------------------------------------------

(defn body-of
  ``The JSON document a notification becomes. A projection of the
  normalized notification and nothing else — which is why the receipt,
  the log and a test all read the same string.``
  [note]
  (json/encode
    {:id (note :id)
     :key (string (note :key))
     :at (note :at)
     :title (note :title)
     :body (get note :body)
     :url (get note :url)
     :data (get note :data {})}))

(defn signature
  ``The `X-Void-Signature` value for a body at `at`: `t=<unix>,v1=<hex
  hmac-sha256 of "<t>.<body>">`. nil when no secret is configured —
  an unsigned webhook to an endpoint that does not check one is a
  decision, and it is made by leaving `[:notify-webhook :signing-key]`
  unset.``
  [body &opt at secret]
  (default at (os/time))
  (default secret (get settings :signing-key))
  (when (and secret (not (empty? (string secret))))
    (string "t=" at ",v1="
            (crypto/hex (crypto/hmac-sha256 (string secret)
                                            (string at "." body))))))

# -- failures ------------------------------------------------------------

(defn webhook-error
  "The value a failed delivery throws: the endpoint's own answer, so
  that `permanent?` can read the status off it."
  [status url &opt body]
  {:notify/webhook true
   :status status
   :url url
   :message (string "webhook " url " answered " status
                    (if (and body (not (empty? (string body))))
                      (string ": " (string/slice (string body) 0 (min 200 (length body))))
                      ""))})

(def retry-anyway
  "4xx codes that mean \"later\" rather than \"no\": a receiver that is
  rate-limiting or timing out has not given a final answer."
  [408 429])

(defn permanent?
  ``Has the receiver already answered for good? A 4xx is the endpoint
  saying no — a wrong URL, a signature it will not accept — and no
  number of retries changes it; 5xx and a connection that broke are
  the queue's business. A delivery this channel *refused to attempt*
  (`:blocked` — the address failed `target-refusal`) is permanent too:
  the address does not get better with retries.``
  [err]
  (def status (get err :status))
  (truthy? (or (get err :blocked)
               (and (number? status)
                    (>= status 400) (< status 500)
                    (not (index-of status retry-anyway))))))

# -- where a notification may point a POST -------------------------------
#
# The endpoint of a per-notification delivery comes from the
# notification itself (`:to {:url ...}` or the `:webhook` override) —
# which is to say, from whoever could get a notification created. An
# unfiltered value there is a POST to loopback, to a private network or
# to the cloud metadata address, with a body the caller shaped: the
# textbook SSRF. The name is resolved here and the *resolved* addresses
# are judged, so `http://internal.example` pointing at 10.0.0.5 is
# refused the same as the literal address.
#
# The range check is deliberately a small pure function in this module
# rather than an import: void/notify has no edge to void/security
# (scripts/packages.janet), and one CIDR containment over a parsed
# address is cheaper to own than a package edge is.

(defn- parse-ipv4 [s]
  (def groups (string/split "." (string s)))
  (when (= 4 (length groups))
    (def parts (seq [g :in groups
                     :let [n (when (and (not (empty? g))
                                        (all |(and (>= $ (chr "0")) (<= $ (chr "9"))) g))
                              (scan-number g))]]
                 (if (and n (int? n) (<= 0 n 255)) n -1)))
    (unless (index-of -1 parts) (tuple ;parts))))

(defn- parse-ipv6 [s0]
  (def s (string s0))
  (when (string/find ":" s)
    (def [ok bytes]
      (protect
        (do
          (def [head tail] (if-let [j (string/find "::" s)]
                             [(string/slice s 0 j) (string/slice s (+ j 2))]
                             [s nil]))
          (defn groups [text]
            (if (or (nil? text) (empty? text))
              @[]
              (seq [g :in (string/split ":" text)
                    :let [n (scan-number (string "0x" g))]]
                (do (unless (and n (int? n) (<= 0 n 0xffff))
                      (error "not a group"))
                    n))))
          (def hs (groups head))
          (def ts (groups tail))
          (def fill (- 8 (+ (length hs) (length ts))))
          (when (or (neg? fill) (and (nil? (string/find "::" s)) (pos? fill)))
            (error "wrong group count"))
          (def out @[])
          (each g hs (array/push out (brshift g 8)) (array/push out (band g 0xff)))
          (for _ 0 fill (array/push out 0) (array/push out 0))
          (each g ts (array/push out (brshift g 8)) (array/push out (band g 0xff)))
          (tuple ;out))))
    (when ok bytes)))

(defn- in-prefix? [bytes prefix bits]
  (and (>= (* 8 (length bytes)) bits)
       (do
         (var same true)
         (var left bits)
         (var i 0)
         (while (and same (pos? left))
           (def mask (if (>= left 8) 0xff (band 0xff (blshift 0xff (- 8 left)))))
           (unless (= (band mask (in bytes i)) (band mask (in prefix i)))
             (set same false))
           (-= left (min 8 left))
           (++ i))
         same)))

(def- blocked-v4
  # loopback, RFC 1918, link-local (the cloud metadata range), "this
  # network" — each as [prefix-bytes bits]
  [[[127 0 0 0] 8] [[10 0 0 0] 8] [[172 16 0 0] 12] [[192 168 0 0] 16]
   [[169 254 0 0] 16] [[0 0 0 0] 8]])

(def- blocked-v6
  # ::1, ::, link-local, ULA
  [[[0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1] 128]
   [[0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0] 128]
   [[0xfe 0x80 0 0 0 0 0 0 0 0 0 0 0 0 0 0] 10]
   [[0xfc 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0] 7]])

(defn private-address?
  ``Is this address (v4 or v6, as text) one a webhook must not reach
  by default — loopback, RFC 1918, link-local, ULA or unspecified?
  An address that does not parse is treated as private: what cannot
  be judged is not sent to.``
  [address]
  (def s (string address))
  # a v4-mapped v6 address is the v4 address it carries
  (def v4 (or (parse-ipv4 s)
              (when (string/has-prefix? "::ffff:" (string/ascii-lower s))
                (parse-ipv4 (string/slice s 7)))))
  (def v6 (when (nil? v4) (parse-ipv6 s)))
  (cond
    v4 (truthy? (some (fn [[prefix bits]] (in-prefix? v4 prefix bits)) blocked-v4))
    v6 (truthy? (some (fn [[prefix bits]] (in-prefix? v6 prefix bits)) blocked-v6))
    true))

(defn- allow-entry-admits? [entry address]
  # an :allow-hosts entry that is a CIDR (or a bare address) admits an
  # address inside it
  (def e (string entry))
  (if-let [i (string/find "/" e)]
    (let [prefix-text (string/slice e 0 i)
          bits (scan-number (string/slice e (inc i)))
          prefix (or (parse-ipv4 prefix-text) (parse-ipv6 prefix-text))
          addr (or (parse-ipv4 address)
                   (when (string/has-prefix? "::ffff:" (string/ascii-lower address))
                     (parse-ipv4 (string/slice address 7)))
                   (parse-ipv6 address))]
      (truthy? (and prefix addr bits (int? bits)
                    (= (length prefix) (length addr))
                    (in-prefix? addr prefix bits))))
    (= (string/ascii-lower e) (string/ascii-lower (string address)))))

(defn- resolved-addresses [host]
  # the literal address as itself; a name through the resolver, every
  # answer judged — the delivery that follows resolves the same name,
  # so what is checked is what will be dialed
  (if (or (parse-ipv4 host) (parse-ipv6 host))
    [host]
    (let [[ok addrs] (protect (net/address host 80 :stream true))]
      (when ok
        (distinct (map |(first (net/address-unpack $)) addrs))))))

(defn target-refusal
  ``Why a per-notification URL must not be POSTed to, or nil when it
  may. The host is allowed outright when `[:notify-webhook
  :allow-hosts]` names it; otherwise its resolved addresses must all
  be public, unless `[:notify-webhook :allow-private]` says this
  deployment means to reach private ones. A URL that does not parse
  is left for `client/post` to refuse with its own words.``
  [url &opt cfg]
  (default cfg settings)
  (def [ok u] (protect (client/parse-url url)))
  (when (and ok (dictionary? u))
    (def host (string (get u :host "")))
    (def allow (map string (get cfg :allow-hosts [])))
    (cond
      (empty? host) nil
      (index-of (string/ascii-lower host) (map string/ascii-lower allow)) nil
      (get cfg :allow-private) nil
      (let [addrs (resolved-addresses host)]
        (cond
          (nil? addrs)
          (string "the host " host " did not resolve")

          (some (fn [a] (and (private-address? a)
                             (not (some |(allow-entry-admits? $ a) allow))))
                addrs)
          (string "the host " host " resolves to a loopback/private/link-local "
                  "address — set [:notify-webhook :allow-hosts] to name it, or "
                  "[:notify-webhook :allow-private] true if this deployment "
                  "means to deliver into its own network"))))))

# -- the channel ---------------------------------------------------------

(defn project
  "The endpoint and the body, or nil when this notification names no
  endpoint and none is configured."
  [note]
  (when-let [url (or (notification/address-for note {:address :url})
                     (get settings :url))]
    (def override (notification/override-for note :webhook))
    {:id (note :id)
     :at (note :at)
     :key (note :key)
     :url (get override :url url)
     :body (or (get override :body) (body-of note))
     :headers (get override :headers {})}))

(def override-header-allowlist
  ``The header names a notification's own `:headers` may set on a
  delivery to a *per-notification* URL. A short list on purpose: the
  interesting headers — authorization above all — belong to the
  configured endpoint, and an override that could name them would
  carry a credential to whatever URL the notification chose.``
  ["content-type" "accept" "user-agent"])

(defn- override-headers [given configured?]
  (if configured?
    given
    (tabseq [[k v] :pairs (or given {})
             :let [name (string/ascii-lower (string k))]
             :when (index-of name override-header-allowlist)]
      name v)))

(defn deliver
  ``POST the projected body, sign it here, and let the status decide
  whether there is anything to retry.

  Two things depend on whether the URL is the *configured* one
  (`[:notify-webhook :url]`) or came off the notification: a
  per-notification URL is checked by `target-refusal` before anything
  is sent, and it never receives `[:notify-webhook :headers]` — those
  are the configured endpoint's credentials, and sending them to an
  address the notification chose would hand them to whoever chose it.``
  [payload]
  (def at (os/time))
  (def body (payload :body))
  # compared at delivery time against the live settings, not trusted
  # off the payload: the payload may have crossed a queue
  (def configured? (and (get settings :url)
                        (= (string (payload :url)) (string (get settings :url)))))
  (unless configured?
    (when-let [why (target-refusal (payload :url) settings)]
      (error {:notify/webhook true
              :blocked true
              :url (payload :url)
              :message (string "webhook " (payload :url) " refused: " why)})))
  (def headers
    (merge {"content-type" "application/json"
            "x-void-notification" (string (payload :id))
            "x-void-event" (string (payload :key))}
           (if configured? (get settings :headers {}) {})
           (override-headers (get payload :headers {}) configured?)
           (if-let [sig (signature body at)] {"x-void-signature" sig} {})))
  (def resp (client/post (payload :url) body
                         {:headers headers
                          :timeout (get settings :timeout 10)}))
  (def status (get resp :status 0))
  (unless (and (>= status 200) (< status 300))
    (error (webhook-error status (payload :url) (get resp :body))))
  (log/debug "webhook delivered" :ns log-ns
             :id (payload :id) :url (payload :url) :status status)
  (channel/receipt :webhook payload {:status status :url (payload :url)}))

(plugin/contribute! :void.notify/channel
  {:name :webhook
   :doc "POST the notification as JSON to [:notify-webhook :url] or to :to {:url ...}"
   :address :url
   :project project
   :deliver deliver
   :permanent? permanent?})

# -- boot ----------------------------------------------------------------

(defn- reveal-secret [cfg]
  (when (config/secret? (get cfg :signing-key))
    (put cfg :signing-key (config/reveal (get cfg :signing-key))))
  cfg)

(defn- check-signing [cfg]
  (when-let [secret (get cfg :signing-key)]
    (unless (empty? (string secret))
      (unless (first (protect (crypto/hmac-sha256 "probe" "probe")))
        (error (string "[:notify-webhook :signing-key] is set and this composition cannot "
                       "sign: the MAC comes from libcrypto through void/crypto — add "
                       ":void/crypto to :plugins, or unset the secret and send the "
                       "webhook unsigned"))))))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 500
   :name :notify-webhook/configure
   :doc "Resolve the [:notify-webhook] slice"
   :fn (fn configure [boot]
         (def cfg (reveal-secret (merge defaults (or (get-in boot [:config :values :notify-webhook]) {}))))
         (set settings cfg)
         (log/info "webhook channel ready" :ns log-ns
                   :url (get cfg :url)
                   :signed (truthy? (get cfg :signing-key))))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   # after the components started, because void/crypto opens libcrypto
   # at :start — before them the probe would fail on every composition,
   # including the ones that are right
   :phase 300
   :name :notify-webhook/signing-check
   :doc "Refuse a secret this process has no library to sign with"
   :fn (fn signing-check [_] (check-signing settings))})

(plugin/defplugin void/notify-webhook
  :doc "The webhook channel of void/notify: one JSON document over void/http/client, signed at delivery with an HMAC over t.body the way a receiver already expects, and a 4xx recorded rather than retried — the endpoint is a value on the notification or one line of config, never a subscription table void would then have to own."
  :version "0.0.1"
  # void/http is a *module* edge and not a plugin one, the void/obs-otlp
  # pose: the client needs no server in this process — a jobs worker
  # with no HTTP kernel at all delivers webhooks
  :requires {:void/core ">=0.0.1" :void/notify ">=0.0.1"}
  :config-key :notify-webhook
  :config-schema Config
  :config-defaults defaults)
