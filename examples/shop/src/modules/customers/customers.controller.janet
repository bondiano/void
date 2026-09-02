### shop/customers/controller — the way in, and the cart that comes
### with it.
###
### Every handler here ends the same way: the service produced an
### identity, `auth-http/login!` puts it in the session and rotates the
### session id, and the cart in hand is adopted. That last line is what
### makes "fill a cart, then sign in at the checkout" work, which is
### the flow a shop lives or dies by — and it is three characters of
### coupling to the cart module rather than a shared table.
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/html/form :as form)
(import void/auth/http :as auth-http)
(import ../../web/layout :as layout)
(import ../cart/cart.session :as cart-session)
(import ./customers.dto :as dto)
(import ./customers.service :as service)
(import ./customers.view :as view)

(defn- start-session!
  "Sign this browser in, and give it back the cart it was holding."
  [req who]
  (auth-http/login! req who)
  (cart-session/adopt! req (service/id-of-subject (who :subject)))
  (ring/redirect "/cart"))

(defn sign-in-page
  "GET /sign-in — three ways in."
  [req]
  (layout/page (view/sign-in-view)))

(defn register
  "POST /register — an account, and the cart that was already in hand."
  [req]
  (def result (form/check dto/Registration (req :form)))
  (def v (result :value))
  (cond
    (not (empty? (result :errors)))
    (layout/page (view/sign-in-view {:register (req :form)
                                     :register-errors (result :errors)}))

    (service/taken? (v :email))
    (layout/page (view/sign-in-view
                   {:register (req :form)
                    :tone "bad"
                    :message "That email already has an account — sign in instead."}))

    (start-session! req ((service/register! v) :identity))))

(defn sign-in
  ``POST /sign-in — the password path, and nothing else.

  Whatever went wrong, the page says the same thing (see
  ./customers.service).``
  [req]
  (def result (form/check dto/Credentials (req :form)))
  (def who (when (empty? (result :errors))
              (service/authenticate (result :value))))
  (if who
    (start-session! req who)
    (layout/page (view/sign-in-view
                   {:sign-in (req :form)
                    :tone "bad"
                    :message "Those credentials do not match an account."}))))

(defn request-link
  ``POST /sign-in/magic — mail a one-time sign-in link.

  The application issues the challenge and says nothing else about it,
  and the answer is the same whether or not the address has an account.``
  [req]
  (def result (form/check dto/MagicLink (req :form)))
  (when (empty? (result :errors))
    (service/request-link! (get-in result [:value :email])))
  (layout/page (view/sign-in-view
                 (if (empty? (result :errors))
                   {:message "If that address has an account, a sign-in link is on its way."}
                   {:magic-link (req :form)
                    :tone "bad"
                    :message "That does not look like an email address."}))))

(defn magic-link
  "GET /auth/magic?h=&c= — the link from the letter."
  [req]
  (def query (or (req :query) {}))
  (if-let [who (service/redeem-link (get query "h") (get query "c"))]
    (do
      (auth-http/login! req who)
      (cart-session/adopt! req (service/id-of-subject (who :subject)))
      (ring/redirect "/"))
    (layout/page (view/sign-in-view
                   {:tone "bad"
                    :message "That sign-in link has expired or has already been used."}))))

(defn sign-out
  "POST /sign-out — drop the identity and rotate the session id."
  [req]
  (auth-http/logout! req)
  (ring/redirect "/"))

# -- routes --------------------------------------------------------------

(def guess-limit
  ``What the sign-in forms are allowed per address per minute. A limit
  on a credential form is not about load: it is the difference between
  a password nobody can guess and a password nobody can guess *this
  week*.``
  {:limit 10 :window 60 :key :ip})

(router/defroutes :shop.customers/routes
  (GET "/sign-in" sign-in-page {:name :session/new :void.authz/policy :public})
  (POST "/sign-in" sign-in
        {:name :session/create :void.authz/policy :public
         :void.security/rate guess-limit})
  (POST "/sign-in/magic" request-link
        {:name :session/request-link :void.authz/policy :public
         :void.security/rate guess-limit})
  # where the letter's link points ([:mail-auth :link-path]). A GET
  # that signs somebody in is safe here for the reason a password POST
  # is not: the credential is in the URL the visitor was mailed, not in
  # a cookie a third-party page could make the browser send
  (GET "/auth/magic" magic-link
       {:name :session/magic-link :void.authz/policy :public})
  # deliberately NOT :void.db/txn — a route transaction would open
  # BEGIN IMMEDIATE before the handler and hold sqlite's one writer
  # through the password KDF, a CPU-bound wait that belongs to no
  # transaction (wave 7 measured what that does to a busy file). The
  # register itself is one INSERT, atomic on its own; the concurrent
  # duplicate is refused by the email's unique index, not by a lock
  (POST "/register" register
        {:name :customers/register :void.authz/policy :public
         :void.security/rate guess-limit})
  (POST "/sign-out" sign-out {:name :session/delete :void.authz/policy :public}))
