(import ../test-support/paths)
(import void/auth/identity :as identity)

(def id (identity/make "user:42" {:via :password :cookie true
                                  :claims {:roles [:admin]} :at 1000}))
(assert (= "user:42" (id :subject)))
(assert (= :password (id :via)))
(assert (id :cookie) "the strategy records whether the credential rode on a cookie — void/security asks")
(assert (identity/identity? id))
(assert (not (identity/identity? {:sub "x"})) "a subject is required, and it is spelled :subject")

(each bad [nil "" 42 {} []]
  (def [ok] (protect (identity/make bad)))
  (assert (not ok) (string/format "%q is not a subject" bad)))

(assert (= "user:1" ((identity/make :user:1) :subject))
        "anything byte-shaped is accepted and normalised to a string — a keyword subject is a keyword the caller had, not a mistake")

(assert (= [:user "42"] (identity/subject-of "user:42")))
(assert (= [:service "billing"] (identity/subject-of "service:billing")))
(assert (= [:unknown "42"] (identity/subject-of "42"))
        "a subject without a colon is somebody else's convention, not an error")
(assert (= [:user "a:b"] (identity/subject-of "user:a:b")) "only the first colon splits")

# -- expiry --------------------------------------------------------------

(assert (not (identity/expired? id)) "no :expires means it does not expire on its own")
(def short-lived (identity/make "user:1" {:expires 500}))
(assert (identity/expired? short-lived 600))
(assert (not (identity/expired? short-lived 400)))

# -- the dyn -------------------------------------------------------------

(assert (nil? (identity/current)) "anonymous is nil, not an empty identity")
(assert (not (identity/authenticated?)))
(assert (nil? (identity/subject)))
(assert (= :none (identity/claim :roles :none)) "and a claim of nobody is the default")

(identity/with-identity id
  (assert (= id (identity/current)))
  (assert (identity/authenticated?))
  (assert (= "user:42" (identity/subject)))
  (assert (deep= [:admin] (identity/claim :roles)))
  (assert (= :none (identity/claim :missing :none)))
  # a fiber inherits the dyn, which is what makes this safe under
  # concurrent requests without anybody passing the identity down
  (def seen @[])
  (ev/go (fn [&] (array/push seen (identity/subject))))
  (ev/sleep 0)
  (assert (deep= @["user:42"] seen)
          "a fiber spawned inside the block sees the same identity"))

(assert (nil? (identity/current)) "and it is gone outside the block")

(print "identity-test ok")
