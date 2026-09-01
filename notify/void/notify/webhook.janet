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
   :headers [:optional :dictionary]})

(def defaults
  ``Defaults of the [:notify-webhook] slice.

  There is no default `:url`: a webhook channel with a made-up endpoint
  would deliver every notification to nowhere in particular. Without
  one, only the notifications that carry `:to {:url ...}` go out, and
  the rest are `:skipped`.``
  {:url nil
   :signing-key nil
   :timeout 10
   :headers {}})

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
  the queue's business.``
  [err]
  (def status (get err :status))
  (truthy? (and (number? status)
                (>= status 400) (< status 500)
                (not (index-of status retry-anyway)))))

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

(defn deliver
  "POST the projected body, sign it here, and let the status decide
  whether there is anything to retry."
  [payload]
  (def at (os/time))
  (def body (payload :body))
  (def headers
    (merge {"content-type" "application/json"
            "x-void-notification" (string (payload :id))
            "x-void-event" (string (payload :key))}
           (get settings :headers {})
           (get payload :headers {})
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
