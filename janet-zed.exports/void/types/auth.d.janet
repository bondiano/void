# Types of void/auth's values, named where they recur.

# An identity: the frozen struct `identity/make` builds, what a strategy establishes and a
# request carries under `keys/identity`.
(def AuthIdentity :typedef
  '{:subject :string :via :keyword :cookie :boolean
   :claims {:keyword :any} :at :number :expires :number?})

# A user record, as a user store's `:find` answers it: the application's own columns.
(def AuthUserRecord :typedef
  '{:keyword :any})

# A :void.auth/user-store (store.janet): who exists, and what their password hash is.
# `normalize-user-store` fills `:secret` and `:claims`; `:update-secret` is optional and
# lets a login rehash — hence open.
(def AuthUserStore :typedef
  '{:name :any
   :find (fn [{:by :keyword :value :any}] (or AuthUserRecord :nil))
   :secret (fn [AuthUserRecord] :string?)
   :subject (fn [AuthUserRecord] :string)
   :claims (fn [AuthUserRecord] {:keyword :any})
   & r})

# An API token as the token store keeps it: the digest, never the secret.
(def AuthTokenRecord :typedef
  '{:id :string :digest :string :subject :string :name :string
   :scopes [:any] :claims {:keyword :any} :created :number
   :expires :number? :used :number?})

# A :void.auth/token-store (store.janet); `normalize-token-store` fills `:shared?`,
# `:touch` and `:list`.
(def AuthTokenStore :typedef
  '{:name :any
   :shared? :boolean
   :find (fn [:string] (or AuthTokenRecord :nil))
   :put (fn [AuthTokenRecord] :any)
   :delete (fn [:string] :any)
   :touch (fn [:string :number] :any)
   :list (fn [:string] [AuthTokenRecord])
   & r})

# A challenge as `challenge/issue` stores it: the digest of handle and code, never the code.
(def AuthChallengeRecord :typedef
  '{:digest :string :subject :string :kind (enum :link :otp)
   :claims {:keyword :any} :created :number :expires :number})

# A :void.auth/challenge-store (store.janet): magic links and one-time codes. `:take`
# answers the record and forgets it in one step.
(def AuthChallengeStore :typedef
  '{:name :any
   :shared? :boolean
   :put (fn [:string AuthChallengeRecord :number] :any)
   :take (fn [:string] (or AuthChallengeRecord :nil))
   :sweep (fn [] :any)
   & r})

# A :void.auth/deliver contribution: gets a challenge's code to the person, called with
# {:kind :subject :handle :code :expires :to :claims :channel}.
(def AuthDeliverer :typedef
  '{:name :keyword :fn (fn [{:kind (enum :link :otp) :subject :string :handle :string
                            :code :string :expires :number & r}] :any)
   & r})

# A strategy after `strategy/normalize`: at least one of `:authenticate` (reads a request)
# and `:verify` (checks credentials handed to it); placed among the others by its
# `:after`/`:before` edges (`order/first-wins`).
(def AuthStrategy :typedef
  '{:name :keyword :cookie :boolean
   :after (or :keyword [:keyword] :nil) :before (or :keyword [:keyword] :nil)
   :authenticate (or (fn [:any] (or AuthIdentity :nil)) :nil)
   :verify (or (fn [:any] (or AuthIdentity :nil)) :nil)
   :challenge (or (fn [:any] :any) :nil)
   & r})

# What `password/check` answers, tagged by `:reason`: only `:ok` carries an identity, and
# only the two lookups that found nobody lack a record.
(def AuthLogin :typedef
  '(or {:reason :ok :identity AuthIdentity :needs-rehash :boolean :record AuthUserRecord}
      {:reason :bad-password :identity :nil :needs-rehash :boolean :record AuthUserRecord}
      {:reason :no-password :identity :nil :needs-rehash :boolean :record AuthUserRecord}
      {:reason :no-such-user :identity :nil :needs-rehash :boolean :record :nil}
      {:reason :bad-selector :identity :nil :needs-rehash :boolean :record :nil}))

# A registered password hasher (hash.janet `hashers`): derives a hash for a PHC id.
(def AuthHasher :typedef
  '{:name :keyword
   :derive (fn [(or :string :buffer) (or :string :buffer) {:keyword :number}] :string)
   :encode-params (fn [{:keyword :number}] :string)
   :version :number? :cost-keys [:keyword]})
