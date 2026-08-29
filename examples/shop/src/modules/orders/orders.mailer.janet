### shop/orders/mailer — the letters, written the way the pages are.
###
### A mail body in void is a **view** (ADR-0026 §4): the same hiccup,
### the same components, rendered through the `:void.html/engine` the
### composition already selected. There is no mail template language
### here because there is no mail template language in void.
###
### The one thing a letter has that a page does not is that it has no
### origin: `/orders/SH-1234` resolves against nothing in a mail
### client, so every link goes through `mail/url`, which builds it from
### `[:mail :base-url]`. A relative one is not a dead link in an inbox
### — it is an error at render time (void/mail/render).
###
### Each function returns a **message table**: `{:subject :view
### :layout}`. Who it is going to is the caller's business
### (./orders.events merges `:to`), which is what makes these three
### functions testable with no mailer, no queue and no address.
(import void/mail :as mail)
(import ../../shared/values :as values)

(defn layout
  ``The frame every letter shares. Inline styles, because a mail
  client is a browser from 2004 and a stylesheet is a thing it may or
  may not fetch.``
  [content context]
  [:html
   [:body {:style "font-family: system-ui, sans-serif; color: #1a1a1a; line-height: 1.5"}
    [:div {:style "max-width: 34rem; margin: 0 auto; padding: 1.5rem"}
     [:p {:style "font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: #6b7280"}
      "void shop"]
     content
     [:hr {:style "border: none; border-top: 1px solid #e5e7eb; margin: 2rem 0 1rem"}]
     [:p {:style "color: #6b7280; font-size: 0.85rem"}
      "You are receiving this because you ordered from "
      [:a {:href (mail/url "/")} "void shop"] "."]]]])

(defn- line-row [item]
  [:tr
   [:td {:style "padding: 0.35rem 0"} (item :name)]
   [:td {:style "padding: 0.35rem 0; text-align: right"} (item :quantity)]
   [:td {:style "padding: 0.35rem 0; text-align: right"}
    (values/format-price (* (item :quantity) (item :unit-price-cents)))]])

(defn- lines-table [items total-cents]
  [:table {:style "width: 100%; border-collapse: collapse; margin: 1rem 0"}
   [:thead
    [:tr [:th {:style "text-align: left"} "Item"]
     [:th {:style "text-align: right"} "Qty"]
     [:th {:style "text-align: right"} "Total"]]]
   [:tbody (seq [i :in items] (line-row i))]
   [:tfoot
    [:tr [:td {:colspan "2" :style "padding-top: 0.6rem; font-weight: 600"} "Total"]
     [:td {:style "padding-top: 0.6rem; text-align: right; font-weight: 600"}
      (values/format-price total-cents)]]]])

(defn receipt
  "What was ordered, and where to look at it."
  [order items]
  {:subject (string "Your order " (order :number))
   :layout layout
   :view [:div
          [:h1 {:style "font-size: 1.4rem"} "Thank you"]
          [:p "We have your order " [:strong (order :number)]
           ". We will charge the card and send another note when it ships."]
          (lines-table items (order :total-cents))
          [:p [:a {:href (mail/url (string "/orders/" (order :number)))}
               "Track this order"]]]})

(defn cancelled
  ``The letter nobody wants to send, and the reason it exists: an order
  that was placed and then could not be paid for has to be *said*, or
  the customer finds out by the parcel never arriving.``
  [order reason]
  {:subject (string "Order " (order :number) " could not be completed")
   :layout layout
   :view [:div
          [:h1 {:style "font-size: 1.4rem"} "We could not take the payment"]
          [:p "Order " [:strong (order :number)] " has been cancelled: "
           [:em (string reason)] "."]
          [:p "Nothing has been charged, and everything is back in the shop —"
           " you are welcome to try again."]
          [:p [:a {:href (mail/url "/")} "Back to the shop"]]]})

(defn shipped
  "The one people actually open."
  [order]
  {:subject (string "Order " (order :number) " is on its way")
   :layout layout
   :view [:div
          [:h1 {:style "font-size: 1.4rem"} "It has shipped"]
          [:p "Order " [:strong (order :number)] " left us today."]
          [:p [:a {:href (mail/url (string "/orders/" (order :number)))}
               "See the order"]]]})
