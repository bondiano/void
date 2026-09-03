### auth/model — what an account is.
###
### The table is **the application's**: void/auth-db reads it
### (`[:auth-db :users]` in config/default.janet says which column means
### what) and never writes to it, which is why registration and a password
### change are handlers in this module rather than something a plugin does
### behind them.
(import void/db :as db)

(db/defentity User
  {:id [:int {:db/pk true :db/type "integer"}]
   :email [:string {:format :email :db/unique true :db/type "text"}]
   # a PHC string ($scrypt$ln=14,r=8,p=1$…), written by
   # `auth/hash-password` and read by void/auth-db's user store. It is
   # optional because an account that only ever arrives by link never
   # sets one — and void/auth's password strategy answers
   # :no-password for it after spending the time it would have spent
   # on a real check
   :password-hash [:optional [:string {:db/type "text"}]]
   :verified-at [:optional [:string {:db/type "text"}]]
   :created-at [:optional [:string {:db/type "text"}]]}
  :db/table "users")
