### auth/view — the six pages an account has, as hiccup.
###
### Plain functions returning data, and nothing here knows that HTTP
### exists: `state` is whatever the controller wants re-rendered —
### `:values` and `:errors` put an invalid submission back in the form
### annotated, `:message` is the one line a page is allowed to say.
###
### **Nothing here says a word about CSRF.** `form/form` has been
### splicing the token slot since wave 1 and void/security binds it
### (ADR-0025) — these forms carry a token because they are forms.
(import void/html/form :as form)
(import void/http/wire :as wire)
(import ./auth.dto :as dto)

(defn- message-line [state]
  (when-let [m (get state :message)] [:p {:class "message"} m]))

(defn register-view
  "The sign-up page."
  [&opt state]
  (default state {})
  [:div {:id "register"}
   [:h1 "Create an account"]
   (message-line state)
   (form/form dto/Registration
     {:action "/register"
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Create an account"})
   [:p [:a {:href "/login"} "Already have an account?"]]])

(defn login-view
  "The sign-in page. :next is where the visitor was going before
  void/auth-http sent them here."
  [&opt state]
  (default state {})
  (def target (get state :next))
  [:div {:id "login"}
   [:h1 "Sign in"]
   (message-line state)
   (form/form dto/Credentials
     {:action (if target (string "/login?next=" (wire/url-encode target)) "/login")
      :values (get state :values)
      :errors (get state :errors)
      :fields {:password {:type "password"}}
      :submit "Sign in"})
   [:p [:a {:href "/password/reset"} "Forgot your password?"] " · "
    [:a {:href "/register"} "Create an account"]]])

(defn reset-view
  "Ask for the address a reset link goes to."
  [&opt state]
  (default state {})
  [:div {:id "reset"}
   [:h1 "Reset your password"]
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
  [:div {:id "password"}
   [:h1 "Choose a new password"]
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
  [:div {:id "verify"}
   [:h1 "Your address"]
   (if (get record :verified-at)
     [:p {:class "message"}
      (string (get record :email "") " is confirmed.")]
     [:div
      [:p "We sent a confirmation link to "
       [:strong (get record :email "")] "."]
      (form/form {} {:action "/verify" :submit "Send it again"})])])

(defn notice-view
  "One line, and nothing to fill in."
  [message]
  [:div {:id "notice"} [:p {:class "message"} message]])
