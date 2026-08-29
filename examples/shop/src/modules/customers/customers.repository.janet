### shop/customers/repository — every query about a customer.
###
### Three functions, and that is the point: the *authentication*
### queries — is this password right, is this token still valid, has
### this challenge been redeemed — are not here and are not this
### application's to write. void/auth-db reads the same table through
### the column names in config/default.janet, which is why signing in
### needs no repository at all.
(import void/db :as db)
(import ../../shared/values :as values)
(import ./customers.model :as model)

(defn find-by-id
  "One customer by primary key, or nil."
  [id]
  (db/find model/Customer id))

(defn find-by-email
  "One customer by address, or nil."
  [email]
  (db/one model/Customer {:where [:= :email email]}))

(defn create!
  ``Insert a customer. The caller passes a **hash**, never a password:
  hashing is a decision about cost and algorithm, and it belongs in
  ./customers.service where it is made once.``
  [{:name name :email email :role role :password-hash hash}]
  (db/insert! model/Customer {:name name
                              :email email
                              :role (or role "customer")
                              :password-hash hash
                              :created-at (values/now)}))
