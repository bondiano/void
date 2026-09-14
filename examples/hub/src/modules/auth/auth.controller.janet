### auth/controller — register, sign in, sign out, reset, verify.
###
### Twelve routes, and every handler is the same three moves: unpack the
### request, call the service, pick the view. The rules are in
### ./auth.service.janet — which account exists, what a challenge is
### for, what a password becomes — and the only thing this layer knows
### that the service does not is the session: `login!` and `logout!`
### take the request, because a session is a thing a browser has.
###
### Handlers are registered as symbols, so redefining one in the repl — or
### saving this file with `void dev` running — is live.
(import void/auth/http :as auth-http)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/html/form :as form)
(import ../../web/layout :as layout)
(import ./auth.dto :as dto)
(import ./auth.service :as accounts)
(import ./auth.view :as view)

(defn register-form
  "GET /register"
  [req]
  (layout/page (view/register-view)))

(defn register
  "POST /register — an account with a password."
  [req]
  (form/submit dto/Registration (req :form)
    {:ok (fn [v]
           (def out (accounts/register! (v :email) (v :password)))
           (if (= :taken (out :status))
             (layout/page (view/register-view
                            {:values (req :form)
                             :message "That address already has an account — sign in instead."}))
             (do
               (auth-http/login! req (out :identity))
               (ring/redirect "/"))))
     :invalid (fn [values errors]
                (layout/page (view/register-view {:values values :errors errors})))}))

(defn login-form
  "GET /login — where [:auth-http :login-path] points."
  [req]
  (layout/page (view/login-view {:next (get (or (req :query) {}) "next")})))

(defn login
  ``POST /login — the password path, and nothing else.

  Whatever went wrong, the page says the same thing: the service spends
  the same time on an unknown address as on a wrong password, and
  telling the visitor which it was would hand that distinction straight
  back.``
  [req]
  (defn refused [values]
    (layout/page (view/login-view {:values values
                                   :next (get (or (req :query) {}) "next")
                                   :message "Those credentials do not match an account."})))
  (form/submit dto/Credentials (req :form)
    {:ok (fn [v]
           (if-let [identity (accounts/authenticate v)]
             (do
               (auth-http/login! req identity)
               # where the visitor was going, as a path of this
               # application and nothing else — a `next` that is
               # somebody else's origin is an open redirect with a
               # sign-in page attached, and the hand-rolled reader that
               # used to live here did not even refuse /\evil.example
               # (a browser normalizes it to the same URL)
               (ring/redirect (auth-http/safe-next req)))
             (refused (req :form))))
     :invalid (fn [values _] (refused values))}))

(defn logout
  "POST /logout — drop the identity and rotate the session id."
  [req]
  (auth-http/logout! req)
  (ring/redirect "/"))

(defn reset-form
  "GET /password/reset"
  [req]
  (layout/page (view/reset-view)))

(defn request-reset
  ``POST /password/reset — mail a link that signs them in long enough to
  choose a new password.

  **The answer is the same whether or not the address has an account.**
  A page that said "no such account" would be a way to ask this
  application who its users are, one address at a time — the same
  reasoning that makes an unknown login cost what a real one does.``
  [req]
  (form/submit dto/EmailOnly (req :form)
    {:ok (fn [v]
           (when-let [record (accounts/record-for-email (v :email))]
             (accounts/send-reset! record))
           (layout/page (view/reset-view
                          {:values (req :form)
                           :message "If that address has an account, a link is on its way."})))
     :invalid (fn [values _]
                (layout/page (view/reset-view
                               {:values values
                                :message "That does not look like an email address."})))}))

(defn link
  "GET /auth/link?h=&c= — the one path a letter points at
  ([:mail-auth :link-path]), for both challenges."
  [req]
  (def query (or (req :query) {}))
  (if-let [identity (accounts/redeem (get query "h") (get query "c"))]
    (do
      (auth-http/login! req identity)
      (if (= "reset" (accounts/purpose-of identity))
        (ring/redirect "/password/edit")
        (do
          (accounts/confirm-address! identity)
          (ring/redirect "/"))))
    (layout/page (view/login-view
                   {:message "That link has expired or has already been used."}))))

(defn password-form
  "GET /password/edit"
  [req]
  (layout/page (view/password-view)))

(defn update-password
  "POST /password — the route is :required, so there is somebody to
  change the password of."
  [req]
  (def record (accounts/current-record))
  (form/submit dto/NewPassword (req :form)
    {:ok (fn [v]
           (if record
             (do
               (accounts/change-password! record (v :password))
               (layout/page (view/notice-view "Your password has been changed.")))
             (layout/page (view/password-view {:values (req :form)}))))
     :invalid (fn [values errors]
                (layout/page (view/password-view {:values values :errors errors})))}))

(defn verify-form
  "GET /verify"
  [req]
  (layout/page (view/verify-view (accounts/current-record))))

(defn resend-verification
  "POST /verify — another confirmation link for the signed-in account.
  A confirmed address does not get one: the link signs whoever holds it
  in, and there is no reason to keep minting those."
  [req]
  (when-let [record (accounts/current-record)]
    (unless (record :verified-at)
      (accounts/send-verification! record)))
  (layout/page (view/notice-view "A confirmation link is on its way.")))

# -- routes --------------------------------------------------------------
#
# Every route says what access it needs rather than leaning on
# [:auth-http :default]: the default is :public, an application that
# flips it to :required has taken a deny-by-default posture on purpose,
# and these twelve routes have to keep meaning the same thing under both.
# The names are also what a policy asks about — one name, read by more
# than one thing.

(router/defroutes :hub/auth-routes
  (GET "/register" register-form {:name :auth/register-form
                                  :void.auth/access :public})
  (POST "/register" register {:name :auth/register
                              :void.auth/access :public})
  (GET "/login" login-form {:name :auth/login-form
                            :void.auth/access :public})
  (POST "/login" login {:name :auth/login
                        :void.auth/access :public})
  (POST "/logout" logout {:name :auth/logout
                          :void.auth/access :public})
  (GET "/password/reset" reset-form {:name :auth/reset-form
                                     :void.auth/access :public})
  (POST "/password/reset" request-reset {:name :auth/reset-request
                                         :void.auth/access :public})
  # a GET that signs somebody in is safe here for the reason a password
  # POST is: the credential is in the URL and it is single-use
  (GET "/auth/link" link {:name :auth/link :void.auth/access :public})
  (GET "/password/edit" password-form {:name :auth/password-form
                                       :void.auth/access :required})
  (POST "/password" update-password {:name :auth/password-update
                                     :void.auth/access :required})
  (GET "/verify" verify-form {:name :auth/verify-form
                              :void.auth/access :required})
  (POST "/verify" resend-verification {:name :auth/verify-resend
                                       :void.auth/access :required}))
