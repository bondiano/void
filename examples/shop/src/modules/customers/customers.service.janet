### shop/customers/service — signing up, signing in, and being asked
### who you are.
###
### Nothing in this file touches a request or a session. `login!` is a
### cookie operation and lives in ./customers.controller; what is here
### is the part that is about a customer: hash a password, check a pair
### of credentials, mint a challenge, unpack a subject string.
###
### **`register!` does not trust what it just inserted.** It hashes,
### inserts, and then goes through the ordinary password path to get an
### identity — so there is exactly one way an identity is minted in
### this application, and a change to it cannot miss the sign-up.
(import void/auth :as auth)
(import ./customers.repository :as repo)

(defn id-of-subject
  ``The customer id inside a subject string. The subject is
  `"customer:42"` — `[:auth-db :users :subject-kind]` is the
  `customer` half — so this is the one place the application unpacks
  it.``
  [subject]
  (when subject (scan-number (last (auth/subject-of subject)))))

(defn current-id
  "The signed-in customer's id, or nil."
  []
  (when-let [id (auth/current-user)]
    (id-of-subject (id :subject))))

(defn current
  "The signed-in customer's row, or nil."
  []
  (when-let [id (current-id)]
    (repo/find-by-id id)))

(defn taken?
  "Is this address already an account?"
  [email]
  (truthy? (repo/find-by-email email)))

(defn register!
  ``Create an account and return `{:customer <row> :identity <id>}`.

  `auth/hash-password` produces a PHC string: the algorithm and its
  cost travel inside the value, so raising the cost later is a config
  change rather than a migration nobody can write.``
  [{:name name :email email :password password}]
  (def customer (repo/create! {:name name
                               :email email
                               :role "customer"
                               :password-hash (auth/hash-password password)}))
  (def check (auth/check-password (auth/user-store) {:email email :password password}))
  {:customer customer :identity (get check :identity)})

(defn authenticate
  ``The password path, and the identity it produces — or nil.

  Whatever went wrong, the caller is told the same thing:
  `check-password` distinguishes an unknown address from a wrong
  password and spends the same time on both (it hashes even when there
  is no user), and returning the difference would hand it back.``
  [credentials]
  (get (auth/check-password (auth/user-store) credentials) :identity))

(defn request-link!
  ``Mint a one-time sign-in challenge for an address, if it has an
  account. Returns nothing either way — **the answer is the same
  whether or not the address is known**, because a page that said "no
  such account" would be a way to ask this shop who its customers are,
  one address at a time.

  `auth/challenge!` mints a single-use code, stores its digest and
  hands it to the deliverers; void/mail-auth turns that into a letter
. Which is why there is no template, no URL and no
  token in this application.``
  [email]
  (when-let [customer (repo/find-by-email email)]
    (auth/challenge! (string "customer:" (customer :id))
                     {:to (customer :email)
                      :claims {:name (customer :name) :role (customer :role)}})
    customer))

(defn redeem-link
  ``The link from the letter, as an identity or nil. `redeem!` takes
  the challenge out of the store before it checks the code, so a link works once and a wrong one is spent.``
  [handle code]
  (auth/redeem! handle code))

(defn ensure-account!
  ``Create an account with a role, or leave the one that is there
  alone. The seed's idempotence lives here rather than in the seed,
  because "an account that exists keeps its password" is a rule about
  accounts.``
  [{:name name :email email :password password :role role}]
  (if-let [existing (repo/find-by-email email)]
    [:kept existing]
    [:created (repo/create! {:name name
                             :email email
                             :role role
                             :password-hash (auth/hash-password password)})]))
