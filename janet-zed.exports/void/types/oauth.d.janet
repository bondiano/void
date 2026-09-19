# Types of void/oauth's values, named where they recur.

# One opened JWKS key of a provider: `provider/refresh-keys!` builds it.
(def OauthKey :typedef
  '{:alg :keyword :key :any :kid :string?})

# A provider's ring: the table `provider/make-ring` builds and the :oauth/providers
# component holds per provider — its discovered metadata and opened keys.
(def OauthRing :typedef
  '@{:metadata (or {:keyword :any} :nil) :keys @{:string OauthKey}
    :fetched :number :last-attempt :number :error :string?})

# A token-endpoint exchange as data: what `flow/token-request` and `refresh-request` build
# and the client sends.
(def OauthRequest :typedef
  '{:method :keyword :url :string :form @{:keyword :any} :headers @{:string :string}
   :timeout :any})
