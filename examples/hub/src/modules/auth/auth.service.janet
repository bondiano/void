### auth/service — what an account *is*, in the two directions this
### application needs it.
###
### An identity is `{:subject "user:42" ...}` and nothing more
### (ADR-0023): void does not know what a user is, and this file is
### where this application says so — the subject string, the row behind
### it, and the three things that may happen to an account.
###
### Nothing here sees a request. The signed-in identity arrives on a dyn
### key rather than as an argument (ADR-0024), which is why
### `current-record` is a service function and not a controller one;
### what is left for the controller is the session — `login!` and
### `logout!` are the only things that need the request itself.
###
### **Reset and verification are one flow.** `auth/challenge!` mints a
### single-use code and hands it to whatever delivers (`:void/mail-auth`
### is one; a challenge nobody delivered is an error, ADR-0023 §7).
### There is **one** route that redeems, because a deliverer builds one
### URL — from `[:mail-auth :link-path]` — and which of the two the link
### was for is a claim that travelled on the challenge.
(import void/auth :as auth)
(import ./auth.repository :as repo)

(defn subject-string
  "The subject a record signs in as — `[:auth-db :users :subject-kind]`
  is the `user` half of it."
  [record]
  (string "user:" (record :id)))

(defn record-of
  "The row an identity points at, or nil."
  [id]
  (when id
    (when-let [n (scan-number (last (auth/subject-of (id :subject))))]
      (repo/by-id n))))

(defn current-record
  "The signed-in account as a row, or nil."
  []
  (record-of (auth/current-user)))

(defn record-for-email
  "The account at an address, or nil — what the reset flow asks for
  before it decides to say nothing about the answer."
  [email]
  (repo/by-email email))

(defn send-verification!
  ``Ask somebody to confirm the address they registered with. The claim
  is what tells this challenge from a password reset when the link comes
  back — `challenge!` refuses if nobody delivered it, which is the
  failure you want: a page that spins forever with nothing in any log is
  the other one.``
  [record]
  (auth/challenge! (subject-string record)
                   {:to (record :email)
                    :claims {:purpose "verify"}}))

(defn send-reset!
  "Mail a link that signs somebody in long enough to choose a new
  password."
  [record]
  (auth/challenge! (subject-string record)
                   {:to (record :email)
                    :claims {:purpose "reset"}}))

(defn register!
  ``Create an account and answer with the identity it signs in as.
  `{:status :taken}` when the address already has one.

  The identity comes back through the ordinary password path rather
  than from the row that was just written: one code path signs anybody
  in, so there is one place where that can be wrong.``
  [email password]
  (if (repo/by-email email)
    {:status :taken}
    (let [record (repo/create! email (auth/hash-password password))
          check (auth/check-password (auth/user-store)
                                     {:email email :password password})]
      (send-verification! record)
      {:status :created :record record :identity (check :identity)})))

(defn authenticate
  ``The identity behind a password, or nil.

  `check-password` distinguishes an unknown address from a wrong
  password and spends the same time on both (it hashes even when there
  is no account) — so the caller gets one answer and cannot hand that
  distinction back to whoever asked.``
  [credentials]
  (get (auth/check-password (auth/user-store) credentials) :identity))

(defn redeem
  ``The identity a link carries, or nil when it has expired or been
  used.

  `redeem!` takes the challenge out of the store *before* it checks the
  code (ADR-0023 §7), so a link works once and a wrong one is spent: the
  visitor asks for another, which costs them a click and an attacker a
  full guess per try.``
  [handle code]
  (auth/redeem! handle code))

(defn purpose-of
  "What a redeemed link was for — a claim that travelled on the
  challenge, so there is no second table and no second route."
  [identity]
  (get-in identity [:claims :purpose]))

(defn confirm-address!
  "Stamp the address of a redeemed verification link."
  [identity]
  (repo/mark-verified! (record-of identity)))

(defn change-password!
  "Set a new password on an account that is already signed in."
  [record password]
  (repo/set-password-hash! (record :id) (auth/hash-password password)))
