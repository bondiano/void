(import ../void/core/errors :as errors)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string name ": message " (string/format "%q" err) " lacks " (string/format "%q" pat))))

# -- make / raise --------------------------------------------------------

(def e (errors/make :test/thing "went wrong" {:id 7}))
(assert (errors/error? e))
(assert (= :test/thing (errors/kind e)))
(assert (= "went wrong" (errors/message e)))
(assert (= 7 (get (errors/data e) :id)))
(assert (= 500 (errors/status e)) "a kind with no default status means 500")
(assert (nil? (e :http/status)) "no status, no v1 spelling either")

(errors/define! :test/dup {:status 409 :doc "a duplicate"})
(def d (errors/make :test/dup))
(assert (= 409 (errors/status d)) "the kind's default status")
(assert (= 409 (d :http/status)) "written under the v1 key as well")
(assert (= "test/dup" (errors/message d)) "no message: the kind's name stands in")
(assert (= 418 (errors/status (errors/make :test/dup nil nil 418))) "an explicit status wins")
(assert (deep= @[[:test/dup {:status 409 :doc "a duplicate"}]]
           (filter |(= :test/dup (first $)) (errors/defined))))

(expect-error "kind must be a keyword" "keyword" |(errors/make "x"))
(expect-error "data must be a dictionary" "dictionary" |(errors/make :test/x nil 3))
(expect-error "status must be an HTTP status" "HTTP status" |(errors/define! :test/y {:status 7}))

(def [ok raised] (protect (errors/raise :test/dup "again" {:k 1})))
(assert (not ok))
(assert (deep= raised (errors/make :test/dup "again" {:k 1})) "raise raises make's value")
(assert (errors/kind? raised :test/dup))
(assert (errors/kind? raised [:test/other :test/dup]))
(assert (not (errors/kind? raised :test/other)))

# -- of: every caught shape becomes an envelope ------------------------

(assert (= e (errors/of e)) "an envelope is itself")
(def legacy (errors/of {:http/status 403 :message "forbidden" :void.authz/decision {:allow false}}))
(assert (= :void.http/abort (errors/kind legacy)))
(assert (= 403 (errors/status legacy)))
(assert (= {:allow false} (legacy :void.authz/decision)) "the original keys survive")
(assert (= "forbidden" (errors/message legacy)))
(assert (= 500 (errors/status (errors/of {:message "no status"}))))
(def s (errors/of "kaboom"))
(assert (= :void/panic (errors/kind s)))
(assert (= "kaboom" (errors/message s)))
(assert (= 500 (errors/status s)))
(assert (= :void/deadline (errors/kind (errors/of "deadline expired"))))
(assert (= 504 (errors/status "deadline expired")))
(assert (errors/deadline? "deadline expired"))
(assert (not (errors/deadline? "the deadline expired for x")) "matched whole, never as a substring")
(assert (= :void/panic (errors/kind (errors/of 42))))
(assert (= "42" (errors/message 42)))
(assert (= "test/thing: went wrong" (errors/str e)))

# -- messages translate through the dyn ---------------------------------

(with-dyns [:void.errors/messages {:test/thing "пошло не так"
                                   :test/dup (fn [env] (string "dup of " (get-in env [:data :k])))}]
  (assert (= "пошло не так" (errors/message e)))
  (assert (= "dup of 1" (errors/message raised)))
  (assert (= "kaboom" (errors/message s)) "a kind the dictionary lacks keeps its own message"))

(print "errors-test: all assertions passed")
