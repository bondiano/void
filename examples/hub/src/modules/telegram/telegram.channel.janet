### telegram/channel — the channel this application writes itself.
###
### Telegram is "an application's or a package's channel, on
### demand", and this is that sentence being kept: a channel is a
### contribution with two functions, and neither of them is privileged.
###
###   :project   runs on the fiber that called notify/send — where the
###              request still is — and returns **data**: a chat and a
###              string. Nothing here touches the network.
###   :deliver   takes that data and posts it. With void/notify-jobs
###              composed, this runs on a worker, and the retry delivers
###              the same value the request meant.
###
### `:permanent?` is the difference between a queue that gives up and a
### queue that hammers a bot API: 400/401/403 are telegram saying no — a
### chat that does not exist, a bot that was removed from it — and 429
### and 5xx are it saying later.
###
### The module is one file because it is one adapter: the two halves are
### the contract's, not this application's, and splitting a port in half
### twice is how a directory of eight-line files happens.
(import void/core/plugin :as plugin)
(import void/core/config :as config)
(import void/core/log :as log)
(import void/notify/channel :as channel)
(import void/notify/notification :as notification)
(import void/http/client :as client)
(import spork/json)

(def log-ns "hub.telegram")

(def defaults
  {:api-base "https://api.telegram.org"
   :timeout 10})

(var- settings defaults)

(defn- reveal-token
  "The token out of its box (void/mail does this with an SMTP
  password): a secret reference is resolved at load and revealed here,
  once, rather than travelling through the code as a string."
  [cfg]
  (when (config/secret? (get cfg :token))
    (put cfg :token (config/reveal (get cfg :token))))
  cfg)

(defn- without-blanks
  ``Drop keys whose value is an empty string. A compose file cannot
  leave a variable out conditionally — `${TELEGRAM_BOT_TOKEN:-}` sets it
  to nothing — and a token that is the empty string would be a bot this
  process reports as configured and cannot speak as. Absent and blank
  are the same thing here.``
  [cfg]
  (def out (table/clone cfg))
  (eachp [k v] cfg
    (when (and (string? v) (empty? v)) (put out k nil)))
  out)

(defn configure!
  "Called from the application's :before-start hook (src/app.janet) —
  the bot token and the chat to fall back on."
  [slice]
  (def cfg (reveal-token
             (without-blanks (merge defaults (or (get slice :telegram) {})))))
  (set settings cfg)
  (log/info "telegram channel ready" :ns log-ns
            # whether there is a token, never the token
            :configured (truthy? (get cfg :token))
            :chat (truthy? (get cfg :chat-id))))

(defn configured?
  "Does this process have a bot to speak as?"
  []
  (truthy? (get settings :token)))

# -- the message ---------------------------------------------------------

(defn text-of
  ``The message body: the title, then whatever the notification had room
  to add. Plain text on purpose — telegram's HTML mode would make every
  commit message a thing this application has to escape, and a commit
  message is the last string anybody should trust to be well-formed.``
  [note]
  (def body (get note :body))
  (if (and body (not (empty? (string body))))
    (string (note :title) "\n" body)
    (string (note :title))))

(defn project
  ``The chat and the text, or nil when this notification names no chat
  and none is configured — the shape a channel says "not my business" in
.``
  [note]
  (def chat (or (notification/address-for note {:address :telegram})
                (get settings :chat-id)))
  (when chat
    {:id (note :id)
     :at (note :at)
     :key (note :key)
     :chat-id (string chat)
     :text (text-of note)}))

# -- the network ---------------------------------------------------------

(defn telegram-error
  "What a failed delivery throws: telegram's own answer, so that
  `permanent?` can read the status off it."
  [status body]
  {:hub/telegram true
   :status status
   :message (string "telegram answered " status
                    (if (and body (not (empty? (string body))))
                      (string ": " (string/slice (string body) 0 (min 200 (length body))))
                      ""))})

(def retry-anyway
  "The 4xx that mean \"later\" rather than \"no\": telegram rate-limits
  with 429, and a request that timed out never got an answer at all."
  [408 429])

(defn permanent?
  "Has telegram already answered for good?"
  [err]
  (def status (get err :status))
  (truthy? (and (number? status)
                (>= status 400) (< status 500)
                (not (index-of status retry-anyway)))))

(defn deliver
  "POST sendMessage, and let the status decide whether there is anything
  left to retry."
  [payload]
  (def token (get settings :token))
  (unless token
    # not `permanent?`-able on purpose: a missing token is this
    # deployment's mistake, and a retry after somebody sets it is
    # exactly the right outcome
    (error {:hub/telegram true :message "no [:hub :telegram :token] in this composition"}))
  (def url (string (get settings :api-base) "/bot" token "/sendMessage"))
  (def resp (client/post url
                         (json/encode {:chat_id (payload :chat-id)
                                       :text (payload :text)
                                       :disable_web_page_preview true})
                         {:headers {"content-type" "application/json"}
                          :timeout (get settings :timeout)}))
  (def status (get resp :status 0))
  (unless (and (>= status 200) (< status 300))
    (error (telegram-error status (get resp :body))))
  (log/debug "telegram delivered" :ns log-ns
             :id (payload :id) :chat (payload :chat-id) :status status)
  (channel/receipt :telegram payload {:status status :chat (payload :chat-id)}))

(plugin/contribute! :void.notify/channel
  {:name :telegram
   :doc "Send the notification to a telegram chat — :to {:telegram <chat>} or [:hub :telegram :chat-id]"
   :address :telegram
   :project project
   :deliver deliver
   :permanent? permanent?
   # `:project` runs on the request fiber, where every component of the
   # application is already up; `:deliver` runs on a worker, and a worker
   # is a CLI command that starts what it declared and nothing else.
   # `https://api.telegram.org` is `:tls/lib`, which the queue does not
   # depend on — so the first live delivery failed five times against a
   # very clear message about libssl while void/tls sat composed and
   # unstarted in the same process. This line is that bug, fixed where it
   # is knowable: void/notify-jobs hands the union of the active channels'
   # :needs to the delivery job, and `void jobs work` opens them
   :needs [:tls/lib]})
