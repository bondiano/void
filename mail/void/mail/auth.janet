### void/mail-auth — the letter a magic link travels in.
###
### `void/auth` issues magic links and one-time codes and deliberately
### does not deliver them: delivery is the `:void.auth/deliver` point, so
### that an application which texts its codes never has a mailer in the
### composition. This plugin is the contribution void promised there — the
### one line that closes the loop between 3.2 and 3.5:
###
###     (void/run! {:plugins [:void/mail :void/mail-auth :void/auth ...]})
###     (auth/challenge! (string "user:" (user :id)) {:to (user :email)})
###
### and the visitor gets a letter with a link to
### `[:mail-auth :link-path]` carrying the handle and the code.
###
### **The letter is a view, and it is replaceable without an extension
### point.** `link-view` and `otp-view` are vars holding functions of
### the challenge; an application that wants its own letter sets them
### (`(set mail-auth/link-view my-letter)`). A point would be a second
### way to do what `:void.auth/deliver` already does — an application
### that wants a different letter can also simply contribute its own
### deliverer and leave this plugin out.
###
### **A deliverer that cannot deliver returns nil.** The payload says
### where it is going (`:to`); without an address, or with a
### `:channel` this plugin does not serve, it does nothing and says
### nothing — and `auth/challenge!` is the one that refuses, because it
### is the one that knows that *nobody* delivered.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import ./init :as mail)

# Nothing here calls void/auth: the payload is data and the point is
# declared by this plugin's :requires. The module is loaded for its
# effect — so that `:void.auth/deliver` exists in a composition that
# names this plugin before it names void/auth.
(require "void/auth/init")

(def log-ns "void.mail.auth")

(def Config
  "Schema of the [:mail-auth] config slice."
  {:app-name [:optional :string]
   :link-path [:optional :string]
   :subject [:optional :string]
   :otp-subject [:optional :string]})

(def defaults
  ``Defaults of the [:mail-auth] slice.

  `:link-path` is where the application answers the click. It is a
  path and not a URL: the origin is `[:mail :base-url]`, which every
  other letter already links against.``
  {:app-name nil
   :link-path "/auth/magic"
   :subject nil
   :otp-subject nil})

(var settings
  "The [:mail-auth] slice, resolved at :before-start."
  defaults)

(defn app-name
  "What the letter calls this application: [:mail-auth :app-name], or
  the display name of the sender."
  []
  (or (get settings :app-name)
      (when-let [from (get mail/settings :from)]
        (get (mail/parse-address from) :name))
      "this application"))

(defn link-for
  ``The URL a magic link points at. The handle is hex and the code is
  base64url (void/auth mints both), so neither needs escaping — which
  is why this is a string and not a query builder.``
  [challenge]
  (mail/url (string (get settings :link-path "/auth/magic")
                    "?h=" (challenge :handle)
                    "&c=" (challenge :code))))

(defn- minutes-left [challenge]
  (def expires (get challenge :expires))
  (when expires
    (max 1 (math/round (/ (- expires (os/time)) 60)))))

(defn- expiry-line [challenge]
  (if-let [m (minutes-left challenge)]
    (string "The link works for " m " more minute" (if (= 1 m) "" "s") " and once.")
    "The link can be used once."))

(var link-view
  ``The magic-link letter, as hiccup. A var, so that an application
  replaces it with its own without a new extension point.``
  (fn link-letter [challenge]
    (def href (link-for challenge))
    [:div {:style "font-family: system-ui, sans-serif; line-height: 1.5"}
     [:p (string "Here is your sign-in link for " (app-name) ".")]
     [:p [:a {:href href
              :style (string "display: inline-block; padding: 10px 18px; "
                             "background: #1a1a1a; color: #fff; "
                             "text-decoration: none; border-radius: 6px")}
          "Sign in"]]
     [:p {:style "color: #666; font-size: 14px"} (expiry-line challenge)]
     [:p {:style "color: #666; font-size: 14px"}
      "If you did not ask to sign in, you can ignore this message."]]))

(var otp-view
  "The one-time-code letter, as hiccup. A var, like `link-view`."
  (fn otp-letter [challenge]
    [:div {:style "font-family: system-ui, sans-serif; line-height: 1.5"}
     [:p (string "Your sign-in code for " (app-name) ":")]
     [:p {:style "font-size: 28px; letter-spacing: 6px; font-weight: 600"}
      (challenge :code)]
     [:p {:style "color: #666; font-size: 14px"}
      (if-let [m (minutes-left challenge)]
        (string "The code works for " m " more minute" (if (= 1 m) "" "s") " and once.")
        "The code can be used once.")]
     [:p {:style "color: #666; font-size: 14px"}
      "If you did not ask to sign in, you can ignore this message."]]))

(defn- text-for [challenge]
  (if (= :otp (get challenge :kind))
    (string "Your sign-in code for " (app-name) ": " (challenge :code) "\n\n"
            "If you did not ask to sign in, you can ignore this message.\n")
    (string "Here is your sign-in link for " (app-name) ":\n\n"
            (link-for challenge) "\n\n"
            (expiry-line challenge) "\n"
            "If you did not ask to sign in, you can ignore this message.\n")))

(defn subject-for [challenge]
  (or (if (= :otp (get challenge :kind))
        (get settings :otp-subject)
        (get settings :subject))
      (string "Sign in to " (app-name))))

(defn letter
  ``The message for a challenge — public, because a preview in a REPL
  (`(mail/preview (mail-auth/letter ch))`) is how anybody checks what
  a visitor will actually see.``
  [challenge]
  {:to (get challenge :to)
   :subject (subject-for challenge)
   :view ((if (= :otp (get challenge :kind)) otp-view link-view) challenge)
   :text (text-for challenge)})

(defn deliver-challenge
  ``The `:void.auth/deliver` function. Returns the receipt when it
  sent something and nil when the challenge was not its business — a
  channel it does not serve, or a payload with no address in it.``
  [challenge]
  (def channel (get challenge :channel))
  (def to (or (get challenge :to) (get-in challenge [:claims :email])))
  (cond
    (and channel (not= :mail channel)) nil
    (nil? to)
    (do (log/debug "a challenge came with no address to mail it to" :ns log-ns
                   :subject (get challenge :subject) :kind (get challenge :kind))
        nil)
    (let [receipt (mail/send (letter (merge {} challenge {:to to})))]
      (log/info "sign-in challenge mailed" :ns log-ns
                :kind (get challenge :kind) :to to :id (receipt :id))
      receipt)))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :mail-auth/configure
   :doc "Resolve the [:mail-auth] slice"
   :fn (fn configure [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :mail-auth]) {}))))})

(plugin/defplugin void/mail-auth
  :doc "Magic links and one-time codes go out as mail: the :void.auth/deliver contribution void/auth has been waiting for since 3.2, with a letter that is an ordinary view and two vars to replace it."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/mail ">=0.0.1" :void/auth ">=0.0.1"}
  :config-key :mail-auth
  :config-schema Config
  :config-defaults defaults
  :contributes {:void.auth/deliver [{:name :mail/challenge
                                     :doc "Mail a magic link or a one-time code"
                                     :fn deliver-challenge}]})
