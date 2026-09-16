### auth/view — the six pages an account has, as hiccup.
###
### Plain functions returning data, and nothing here knows that HTTP
### exists: `state` is whatever the controller wants re-rendered —
### `:values` and `:errors` put an invalid submission back in the form
### annotated, `:message` is the one line a page is allowed to say.
###
### **Nothing here says a word about CSRF.** `form/form` has been
### splicing the token slot since wave 1 and void/security binds it —
### these forms carry a token because they are forms.
(import void/html/form :as form)
(import void/http/wire :as wire)
(import ./auth.dto :as dto)

(def- card
  "One card, six pages. A second copy of this string is how they start
  disagreeing."
  "rounded-2xl border border-white/10 bg-slate-900/60 p-8 shadow-2xl shadow-black/40")

(def- title "m-0 mb-6 text-2xl font-semibold tracking-tight text-slate-50")

(def- foot "mt-6 text-sm text-slate-500")

(def- link "text-slate-300 no-underline transition hover:text-emerald-400")

(defn- message-line [state]
  (when-let [m (get state :message)]
    [:p {:class "mb-5 rounded-lg border border-emerald-400/20 bg-emerald-400/10 px-4 py-3 text-sm text-emerald-200"}
     m]))

(defn register-view
  "The sign-up page."
  [&opt state]
  (default state {})
  [:div {:id "register" :class card}
   [:h1 {:class title} "Create an account"]
   (message-line state)
   (form/form dto/Registration
     {:action "/register"
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Create an account"})
   [:p {:class foot} [:a {:class link :href "/login"} "Already have an account?"]]])

(defn login-view
  "The sign-in page. :next is where the visitor was going before
  void/auth-http sent them here."
  [&opt state]
  (default state {})
  (def target (get state :next))
  [:div {:id "login" :class card}
   [:h1 {:class title} "Sign in"]
   (message-line state)
   (form/form dto/Credentials
     {:action (if target (string "/login?next=" (wire/url-encode target)) "/login")
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Sign in"})
   [:p {:class foot}
    [:a {:class link :href "/password/reset"} "Forgot your password?"] " · "
    [:a {:class link :href "/register"} "Create an account"]]])

(defn reset-view
  "Ask for the address a reset link goes to."
  [&opt state]
  (default state {})
  [:div {:id "reset" :class card}
   [:h1 {:class title} "Reset your password"]
   (message-line state)
   (form/form dto/EmailOnly
     {:action "/password/reset"
      :values (get state :values)
      :errors (get state :errors)
      :submit "Mail me a link"})])

(defn password-view
  "Set a new password — reached by following a reset link, or from an
  account page."
  [&opt state]
  (default state {})
  [:div {:id "password" :class card}
   [:h1 {:class title} "Choose a new password"]
   (message-line state)
   (form/form dto/NewPassword
     {:action "/password"
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Save"})])

(defn verify-view
  "Where the confirmation link is asked for again — a link expires, and
  a flow with no way to send a second one is a dead end with a support
  ticket attached."
  [record]
  [:div {:id "verify" :class card}
   [:h1 {:class title} "Your address"]
   (if (get record :verified-at)
     [:p {:class "m-0 rounded-lg border border-emerald-400/20 bg-emerald-400/10 px-4 py-3 text-sm text-emerald-200"}
      [:strong {:class "font-mono font-medium"} (get record :email "")]
      " is confirmed."]
     [:div
      [:p {:class "m-0 leading-relaxed text-slate-400"}
       "We sent a confirmation link to "
       [:strong {:class "font-mono font-medium text-slate-100"} (get record :email "")] "."]
      (form/form {} {:action "/verify" :submit "Send it again"
                     :attrs {:class "quiet-form mt-5"}})])])

(defn notice-view
  "One line, and nothing to fill in."
  [message]
  [:div {:id "notice" :class card}
   [:p {:class "m-0 leading-relaxed text-slate-300"} message]])
