### auth/repository — every query about `users`, and the only file that
### makes one.
###
### void/auth-db reads this table too, through the column names
### `[:auth-db :users]` gives it, and never writes: everything below is
### the writing half, which is the application's.
(import void/db :as db)
(import ../../shared/values :as values)
(import ./auth.model :as model)

(defn by-email
  {:params [:string?]
   :ret (or @{:id :number :email :string :password-hash :string?
              :verified-at :string? :created-at :string? & r} :nil)
   :throws [:string]}
  "The account at an address, or nil."
  [email]
  (when email (db/one model/User {:where [:= :email email]})))

(defn by-id
  {:params [:number?]
   :ret (or @{:id :number :email :string :password-hash :string?
              :verified-at :string? :created-at :string? & r} :nil)
   :throws [:string]}
  "The account with this row id, or nil."
  [id]
  (when id (db/find model/User id)))

(defn create!
  {:params [:string :string]
   :ret @{:id :number :email :string :password-hash :string?
          :verified-at :string? :created-at :string? & r}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "A new account with a password already hashed — the plaintext does
  not reach this layer."
  [email password-hash]
  (db/insert! model/User
              {:email email
               :password-hash password-hash
               :created-at (values/iso-now)}))

(defn set-password-hash!
  {:params [:number :string]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Replace the hash on an account."
  [id password-hash]
  (db/update! model/User id {:password-hash password-hash}))

(defn mark-verified!
  {:params [(or @{:id :number :verified-at :any & r} :nil)]
   :ret (or :number :nil)
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Stamp the address as confirmed, once — a second confirmation of the
  same address is not a second fact."
  [record]
  (when (and record (not (record :verified-at)))
    (db/update! model/User (record :id) {:verified-at (values/iso-now)})))
