### shop/customers/view — three ways in on one page.
###
### The page says the same thing whether or not an address has an
### account (./customers.service explains why), so there is no "unknown
### email" state to render here.
(import void/html/form :as form)
(import ../../web/layout :as layout)
(import ./customers.dto :as dto)

(defn sign-in-view
  [&opt state]
  (default state {})
  [:div {:id "sign-in"}
   [:h1 "Sign in"]
   (layout/notice state)
   [:div {:class "panels"}
    [:div {:class "panel"}
     [:h2 "With a password"]
     (form/form dto/Credentials
       {:action "/sign-in"
        :values (get state :sign-in)
        :fields {:password {:type "password"}}
        :submit "Sign in"
        :attrs {:class "void-form"}})]
    [:div {:class "panel"}
     [:h2 "With a link"]
     [:p {:class "lede"} "We mail you one. It works once."]
     (form/form dto/MagicLink
       {:action "/sign-in/magic"
        :values (get state :magic-link)
        :submit "Mail me a link"
        :attrs {:class "void-form"}})]
    [:div {:class "panel"}
     [:h2 "New here"]
     (form/form dto/Registration
       {:action "/register"
        :values (get state :register)
        :errors (get state :register-errors)
        :fields {:password {:type "password"}}
        :submit "Create an account"
        :attrs {:class "void-form"}})]]])
