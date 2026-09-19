# Types of void/authz's values, named where they recur.

# A decision context: the table `context/make` builds; providers memoize into `:attrs`
# and `:used` records what a policy read. A caller may hand its own under `:context` —
# hence open.
(def AuthzContext :typedef
  '@{:subject :any :action :any :resource :any :env {:keyword :any}
    :attrs @{:keyword :any} :used @[:keyword] & r})

# The error `decide/forbidden` raises for a denied decision: a void/core envelope that also
# carries the decision at the top, where a renderer from before the envelope reads it.
(def AuthzForbidden :typedef
  '{:void/error :keyword :message :string? :data {:any :any}
   :void.authz/decision AuthzDecision & r})

# A decision: the value `decide/decide` answers, logs and hands every listener.
(def AuthzDecision :typedef
  '{:allow :boolean :policy :keyword? :policies [:keyword]
   :reason :string? :attrs [:keyword] :subject :string?
   :action :any :us :number})

# A policy after `policy/normalize`: `:fn` answers true, false, or a string — the reason
# it denied.
(def AuthzPolicy :typedef
  '{:name :keyword :fn (fn [AuthzContext] (or :boolean :string :nil)) :doc :string? & r})

# An attribute provider after `context/normalize-provider`: `:fn` answers a dictionary of
# attributes for its group.
(def AuthzProvider :typedef
  '{:name :keyword :for (enum :subject :resource :env)
   :fn (fn [AuthzContext] (or {:keyword :any} :nil)) & r})
