### intake/repository — every query about `deliveries`.
###
### Three of them, and the interesting one is `create!`: it does not
### check for a duplicate, because the column does. `delivery-id` is
### unique in the migration, so a redelivery that races another one is a
### constraint violation rather than a second row — two workers can be
### inside the handler at the same time and only one of them can hold
### that index.
(import void/db :as db)
(import ../../shared/values :as values)
(import ./intake.model :as model)

(defn by-delivery-id
  {:params [:string?] :ret (or @{:id :number :source :string :event :string
                                 :delivery-id :string :repo :string? :sender :string?
                                 :body-key :string :size :number :received-at :string & r}
                               :nil)
   :throws [:string]}
  "The row a sender's delivery id points at, or nil."
  [delivery-id]
  (when delivery-id (db/one model/Delivery {:where [:= :delivery-id delivery-id]})))

(defn by-id
  {:params [:number?] :ret (or @{:id :number :source :string :event :string
                                 :delivery-id :string :repo :string? :sender :string?
                                 :body-key :string :size :number :received-at :string & r}
                               :nil)
   :throws [:string]}
  "The row this application's own id points at, or nil."
  [id]
  (when id (db/find model/Delivery id)))

(defn create!
  {:params [{:source :string :event :string :delivery-id :string?
            :body-key :string :size :number & r}]
   :ret @{:id :number :source :string :event :string :delivery-id :string
          :repo :string? :sender :string? :body-key :string :size :number
          :received-at :string & r}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Write what arrived: where the bytes went, and what a person filters
  by."
  [row]
  (db/insert! model/Delivery (merge {:received-at (values/iso-now)} row)))
