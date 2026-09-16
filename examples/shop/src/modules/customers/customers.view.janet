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
  (def panel "rounded-2xl border border-slate-200 bg-white p-6 shadow-sm")
  (def h2 "m-0 mb-5 text-lg font-semibold")
  [:div {:id "sign-in"}
   [:h1 {:class "text-3xl font-bold tracking-tight"} "Sign in"]
   (layout/notice state)
   [:div {:class "mt-8 grid gap-5 md:grid-cols-3"}
    [:div {:class panel}
     [:h2 {:class h2} "With a password"]
     (form/form dto/Credentials
       {:action "/sign-in"
        :values (get state :sign-in)
        :fields {:password {:type "password"}}
        :submit "Sign in"})]
    [:div {:class panel}
     [:h2 {:class "m-0 mb-1 text-lg font-semibold"} "With a link"]
     [:p {:class "mb-5 mt-0 text-sm text-slate-500"} "We mail you one. It works once."]
     (form/form dto/MagicLink
       {:action "/sign-in/magic"
        :values (get state :magic-link)
        :submit "Mail me a link"})]
    [:div {:class panel}
     [:h2 {:class h2} "New here"]
     (form/form dto/Registration
       {:action "/register"
        :values (get state :register)
        :errors (get state :register-errors)
        :fields {:password {:type "password"}}
        :submit "Create an account"})]]])
