(import ../test-support/paths)
(import void/core/log :as log)
(import void/authz/policy :as policy)
(import void/authz/context :as context)
(import void/authz/decide :as decide)

(log/set-level! "void.authz" :error)

(policy/defpolicy :always "yes" [ctx] true)
(policy/defpolicy :never "no" [ctx] false)
(policy/defpolicy :with-reason "no, and why" [ctx] "the shift is closed")
(policy/defpolicy :own-brand "same brand" [ctx]
  (or (= (context/attr ctx :subject/brand-id) (context/attr ctx :resource/brand-id))
      "brand mismatch"))

(def manager {:subject "user:7" :claims {:brand-id 3}})

# -- the decision is a value ---------------------------------------------

(def yes (decide/decide :always {:subject manager :action :read}))
(assert (yes :allow))
(assert (= :always (yes :policy)))
(assert (nil? (yes :reason)))
(assert (= "user:7" (yes :subject)))
(assert (= :read (yes :action)))
(assert (number? (yes :us)) "and it says what it cost")

(def no (decide/decide :never {:subject manager}))
(assert (not (no :allow)))
(assert (= "policy not satisfied" (no :reason)) "a bare false gets an honest generic reason")

(def why (decide/decide :with-reason {:subject manager}))
(assert (= "the shift is closed" (why :reason)) "a string answer becomes the reason")

(def attrs (decide/decide :own-brand {:subject manager :resource {:brand-id 3}}))
(assert (attrs :allow))
(assert (deep= [:subject/brand-id :resource/brand-id] (tuple ;(attrs :attrs)))
        "the decision records which attributes it read")

# -- can? / ensure! ------------------------------------------------------

(assert (decide/can? :always {:subject manager}))
(assert (not (decide/can? :never {:subject manager})))

(def kept (decide/ensure! :always {:subject manager}))
(assert (kept :allow) "ensure! hands back the decision when it allows")

(def [ok err] (protect (decide/ensure! :with-reason {:subject manager})))
(assert (not ok))
(assert (= 403 (err :http/status)) "a denial raises a 403 the error renderers understand")
(assert (= "forbidden" (err :message)) "and the message says nothing about why")
(assert (= "the shift is closed" (get-in err [:void.authz/decision :reason]))
        "the reason rides on the value, for the log")

# -- several policies mean AND -------------------------------------------

(def both (decide/decide [:always :own-brand] {:subject manager :resource {:brand-id 3}}))
(assert (both :allow))
(assert (deep= [:always :own-brand] (tuple ;(both :policies))))

(def one-fails (decide/decide [:always :own-brand] {:subject manager :resource {:brand-id 9}}))
(assert (not (one-fails :allow)))
(assert (= :own-brand (one-fails :policy)) "the decision names the policy that refused")
(assert (= "brand mismatch" (one-fails :reason)))

(var evaluated @[])
(policy/register! {:name :counted :fn (fn [_] (array/push evaluated :counted) true)})
(decide/decide [:never :counted] {:subject manager})
(assert (empty? evaluated) "evaluation stops at the first deny")

(assert ((decide/decide [] {:subject manager}) :allow)
        "no policies at all is not a denial — the middleware decides whether a route needs one")

(def [ok2] (protect (decide/decide :missing {})))
(assert (not ok2) "an unknown policy is an error rather than a silent allow")

# -- explain shows what enforcement did ----------------------------------

(def out (decide/explain [:always :with-reason :own-brand]
                         {:subject manager :resource {:brand-id 9}}))
(assert (not (out :allow)))
(assert (= 3 (length (out :results))) "explain evaluates every policy, enforcement stops early")
(assert (= :with-reason (out :policy)) "and reports the first that refused")
(assert (deep= [true false false] (tuple ;(map |($ :allow) (out :results)))))
(assert (= "brand mismatch" (get-in out [:results 2 :reason])))
(assert (= 3 (get-in out [:values :subject/brand-id]))
        "with the attribute values it read, which is what makes a deny debuggable")
(assert (= (out :allow) ((decide/decide [:always :with-reason :own-brand]
                                        {:subject manager :resource {:brand-id 9}})
                         :allow))
        "and it agrees with enforcement, because it is the same evaluation")

(def printed @"")
(with-dyns [*out* printed] (decide/print-explanation out))
(def text (string printed))
(each part ["subject   user:7" "DENY" "with-reason" "brand mismatch" "attributes"]
  (assert (string/find part text) part))

# -- the decision log ----------------------------------------------------

(def seen @[])
(decide/listen! :test/spy (fn [d] (array/push seen d)))
(decide/decide :always {:subject manager})
(decide/decide :never {:subject manager})
(assert (= 2 (length seen)) "every decision passes through, allow and deny alike")
(assert (deep= [true false] (tuple ;(map |($ :allow) seen))))
(decide/unlisten! :test/spy)
(decide/decide :always {:subject manager})
(assert (= 2 (length seen)))

(def broken @[])
(decide/listen! :test/broken (fn [_] (error "boom")))
(decide/listen! :test/after (fn [d] (array/push broken d)))
(decide/decide :always {:subject manager})
(assert (= 1 (length broken))
        "a listener that throws does not take the decision — or the request — with it")
(decide/unlisten! :test/broken)
(decide/unlisten! :test/after)

(print "decide-test ok")
