### void/notify-mail — the notification as a letter (ADR-0040 §4).
###
### The channel `void/notify` promises out of the box, and the one that
### shows what the `:project` / `:deliver` split is for. **The letter is
### rendered where `notify/send` was called** — inside the request, with
### its locale, its identity and `[:mail :base-url]` in reach — and what
### travels onward is the octets `void/mail` built. The worker delivers
### *that*, so a retry sends the same letter with the same Message-ID,
### which is exactly the argument ADR-0026 §5 makes about queueing a
### rendered mail rather than the arguments that would render one.
###
### **The delivery goes back through `mail/send-delivery`**, not
### straight to a transport: `[:mail :queue]` keeps meaning what it
### means, so a composition with `void/mail-jobs` and no
### `void/notify-jobs` still mails off the request path. With both
### queues composed a notification's letter passes through both — one
### hop more, and the right one, because the mail queue is where a
### deployment put the relay's rate limit.
###
### **The letter is a view, and it is replaceable without an extension
### point** — the `void/mail-auth` pose: `view` and `text-of` are vars
### holding functions of the notification. Per notification, a `:mail`
### key on the notification itself overrides any part of the message:
###
###     (notify/send {:key :order/shipped :title "Your order shipped"
###                   :to {:email (user :email)}
###                   :mail {:view (orders/shipped-letter order)
###                          :subject "Order #1042 is on its way"}})

(import void/core/plugin :as plugin)
(import void/mail :as mail)
(import ./channel :as channel)
(import ./notification :as notification)

# Loaded for its effect: so that `:void.notify/channel` exists in a
# composition that names this plugin before it names void/notify.
(require "void/notify/init")

(def Config
  "Schema of the [:notify-mail] config slice."
  {:link-label [:optional :string]})

(def defaults
  ``Defaults of the [:notify-mail] slice. `:link-label` is the one
  string this channel invents rather than reads off the notification,
  which is why it is configuration — an application that does not
  answer in English says so once.``
  {:link-label "Open"})

(var settings
  "The [:notify-mail] slice, resolved at :before-start."
  defaults)

(defn link
  ``The absolute URL a notification's `:url` becomes in a letter. A
  mail has no origin (ADR-0026 §4), so this is `mail/url` and nothing
  else — a relative link is an error at render, where it is visible.``
  [note]
  (when-let [u (get note :url)] (mail/url u)))

(var view
  ``The letter, as hiccup. A var, so an application replaces it with
  its own without a new extension point — and a single notification
  overrides it with `{:mail {:view ...}}`.``
  (fn notification-letter [note]
    [:div {:style "font-family: system-ui, sans-serif; line-height: 1.5"}
     [:h1 {:style "font-size: 20px; margin: 0 0 12px"} (note :title)]
     (when-let [b (get note :body)]
       [:p {:style "margin: 0 0 16px"} b])
     (when-let [href (link note)]
       [:p [:a {:href href
                :style (string "display: inline-block; padding: 10px 18px; "
                               "background: #1a1a1a; color: #fff; "
                               "text-decoration: none; border-radius: 6px")}
            (get settings :link-label "Open")]])]))

(var text-of
  "The plain-text half of the letter, as a function of the
  notification. A var, like `view`."
  (fn notification-text [note]
    (string/join
      (filter |(not (nil? $))
              [(note :title)
               (get note :body)
               (link note)])
      "\n\n")))

(defn letter
  ``The message a notification becomes — public, because a preview in
  a REPL (`(mail/preview (notify-mail/letter note "ada@example.com"))`)
  is how anybody checks what a person will actually see.``
  [note to]
  (merge {:to to
          :subject (note :title)
          :view (view note)
          :text (string (text-of note) "\n")
          # the same id the in-app row and the webhook body carry, so
          # two of them can be recognized as one event
          :headers {"X-Void-Notification" (note :id)}}
         (notification/override-for note :mail)))

(defn project
  ``Render the letter and hand back the delivery — data, and the same
  octets on every retry. nil when the notification carries no address
  this channel can read, which is how a channel says "not mine".``
  [note]
  (when-let [to (notification/address-for note {:address :email})]
    {:id (note :id)
     :at (note :at)
     :key (note :key)
     :delivery (mail/build (letter note to))}))

(defn deliver
  "Send the rendered letter through void/mail's own routing."
  [payload]
  (def receipt (mail/send-delivery (payload :delivery)))
  (channel/receipt :mail payload {:mail receipt
                                  :message-id (get receipt :id)
                                  :queued (truthy? (get receipt :queued))}))

(plugin/contribute! :void.notify/channel
  {:name :mail
   :doc "Send the notification as a letter through void/mail"
   :address :email
   :project project
   :deliver deliver
   # a 5xx is the server's final answer: a rejected mailbox is recorded
   # rather than retried five times with backoff (ADR-0026 §3)
   :permanent? mail/permanent-failure?})

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :notify-mail/configure
   :doc "Resolve the [:notify-mail] slice"
   :fn (fn configure [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :notify-mail]) {}))))})

(plugin/defplugin void/notify-mail
  :doc "The mail channel of void/notify: the letter is rendered where send was called — with the request's locale and identity — and the delivery goes back through mail/send-delivery, so [:mail :queue] keeps meaning what it means. The view is a var and a single notification overrides it with a :mail key."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/notify ">=0.0.1" :void/mail ">=0.0.1"}
  :config-key :notify-mail
  :config-schema Config
  :config-defaults defaults)
