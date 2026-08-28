(import ../test-support/paths)
(import void/core/log :as log)
(import void/authz/context :as context)

(log/set-level! "void.authz.context" :error)

# -- namespaced keys only ------------------------------------------------

(assert (deep= [:subject :brand-id] (context/split-key :subject/brand-id)))
(each bad [:role :brandid]
  (def [ok] (protect (context/split-key bad)))
  (assert (not ok) "an attribute without a namespace is an error"))

# -- the built-in fallbacks ----------------------------------------------

(def id {:subject "user:42" :via :password :claims {:role :manager :brand-id 3}})
(def ctx (context/make {:subject id
                        :resource {:brand-id 3 :author-id "user:42" :state :draft}
                        :env {:ip "10.0.0.1"}}))

(assert (= "user:42" (context/attr ctx :subject/subject)))
(assert (= :user (context/attr ctx :subject/kind)) "the kind half of the subject string")
(assert (= "42" (context/attr ctx :subject/id)) "and the id half")
(assert (= :password (context/attr ctx :subject/via)))
(assert (= :manager (context/attr ctx :subject/role)) "anything else is a claim")
(assert (= 3 (context/attr ctx :subject/brand-id)))
(assert (= 3 (context/attr ctx :resource/brand-id)) "a resource attribute is a key of the resource")
(assert (= :draft (context/attr ctx :resource/state)))
(assert (= "10.0.0.1" (context/attr ctx :env/ip)))
(assert (nil? (context/attr ctx :subject/nothing)))
(assert (= :fallback (context/attr ctx :subject/nothing :fallback)))

(def anonymous (context/make {}))
(assert (nil? (context/subject anonymous)) "an anonymous context has no subject")
(assert (nil? (context/attr anonymous :subject/role)) "and no claims to read")

# -- the identity comes from the dyn void/auth publishes -----------------

(with-dyns [context/identity-dyn id]
  (def implicit (context/make {}))
  (assert (= "user:42" (context/subject-string implicit))
          "the current identity is read from :void.auth/identity — a key, not an import (ADR-0024)"))

# -- providers -----------------------------------------------------------

(var calls 0)
(context/register-provider!
  {:name :test/brand
   :for :subject
   :keys [:subject/brand-id]
   :fn (fn [ctx] (++ calls) {:brand-id 7 :region "eu"})})

(def provided (context/make {:subject {:subject "user:1" :claims {}}}))
(assert (= 7 (context/attr provided :subject/brand-id)) "the provider answered")
(assert (= 1 calls))
(assert (= 7 (context/attr provided :subject/brand-id)))
(assert (= 1 calls) "and is not called again for the same decision — the memo is the whole point")
(assert (= "eu" (context/attr provided :subject/region))
        "everything the provider returned is memoized, not only the key that was asked for")
(assert (= 1 calls) "so its neighbour costs nothing")

(def other (context/make {:subject {:subject "user:1" :claims {}}}))
(context/attr other :subject/brand-id)
(assert (= 2 calls) "a different decision resolves again — the memo is per decision")

# a provider is not consulted for keys it does not claim
(def unrelated (context/make {:subject {:subject "user:1" :claims {:role :x}}}))
(assert (= :x (context/attr unrelated :subject/role)))
(assert (= 2 calls) "the provider named :subject/brand-id and nothing else")

# lazily: a context nobody asks costs nothing at all
(def untouched (context/make {:subject {:subject "user:1" :claims {}}}))
(assert (= 2 calls) "building a context calls no provider")

(each bad [{} {:name :p :for :nothing :fn (fn [_])} {:name :p :for :subject}
           {:name :p :for :subject :fn (fn [_]) :keys :subject/x}]
  (def [ok] (protect (context/normalize-provider bad)))
  (assert (not ok) (string/format "%q is not a provider" bad)))

(context/register-provider! {:name :test/brand :for :subject :fn (fn [_] {})})
(assert (= 1 (length (context/provider-names))) "registering the same name replaces it")
(context/deregister-provider! :test/brand)
(assert (empty? (context/provider-names)))

# -- what was read -------------------------------------------------------

(def watched (context/make {:subject id}))
(context/attr watched :subject/role)
(context/attr watched :subject/role)
(context/attr watched :subject/kind)
(assert (deep= [:subject/role :subject/kind] (tuple ;(context/used watched)))
        "the attributes a decision looked at, in order and without repeats")

(print "context-test ok")
