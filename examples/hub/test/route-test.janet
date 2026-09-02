### Routing, as the table of examples it is. Nothing boots here: a rule
### matching a delivery is a pure function of two values, and the whole
### point of writing rules as data was that this file could exist.
(import ../src/modules/routing/routing.dto :as dto)
(import ../src/modules/routing/routing.service :as route)

# -- one field at a time -------------------------------------------------

(assert (route/value-matches? "push" "push"))
(assert (not (route/value-matches? "push" "release")))
(assert (not (route/value-matches? "push" nil))
        "a rule that names a field does not match a delivery without one")
(assert (route/value-matches? ["push" "release"] "release")
        "a list is any of these")
(assert (not (route/value-matches? ["push" "release"] "issues")))
(assert (not (route/value-matches? {:regex "pu.*"} "push"))
        "a rule this application does not understand matches nothing — the safe
        reading, because the other one sends everything to the wrong place")

# -- a rule over a delivery ----------------------------------------------

(def delivery
  {:source "github" :event "push"
   :repo "bondiano/void" :sender "bondiano"
   :delivery-id "ce4b1f00" :body-key "github/2026/09/ce4b1f00.json"})

(assert (route/matches? {:when {:event "push"}} delivery))
(assert (route/matches? {:when {:event "push" :repo "bondiano/void"}} delivery)
        "every field of :when has to hold — it is a conjunction")
(assert (not (route/matches? {:when {:event "push" :repo "someone/else"}} delivery))
        "and one that does not hold is enough to miss")
(assert (route/matches? {:when {}} delivery)
        "a rule with an empty :when covers everything, which somebody may mean")
(assert (route/matches? {:to [:telegram]} delivery)
        "so does a rule with no :when at all")
(assert (not (route/matches? {:when {:branch "main"}} delivery))
        "a field the row does not have is a field nothing matches — rules are
        written against the row, and a typo in one is silence rather than a
        surprise")

# -- what the message says -----------------------------------------------

(def push-payload
  {:ref "refs/heads/main"
   :commits [{:id "1a2b"} {:id "3c4d"}]
   :head_commit {:message "feat: hub — the receiving end\n\nlonger body"}})

(assert (= "bondiano/void — push by bondiano" (dto/title-of delivery)))
(assert (= "refs/heads/main · 2 commits · feat: hub — the receiving end"
           (dto/body-of delivery push-payload))
        "the first line of the commit message, and never the rest of it")
(assert (= "refs/heads/main · 1 commit · x"
           (dto/body-of delivery {:ref "refs/heads/main"
                                    :commits [{:id "1a2b"}]
                                    :head_commit {:message "x"}}))
        "one commit is one commit")
(assert (nil? (dto/body-of delivery nil))
        "a payload this cannot read says nothing rather than guessing")

(def issue-delivery (merge delivery {:event "issues"}))
(assert (= "opened · storage keys are data"
           (dto/body-of issue-delivery
                          {:action "opened"
                           :issue {:title "storage keys are data"}}))
        "every other event: the action, and what the object calls itself")

(assert (= "bondiano/void — issues by bondiano" (dto/title-of issue-delivery)))
(assert (= "github — push by bondiano"
           (dto/title-of {:source "github" :event "push" :sender "bondiano"}))
        "a delivery whose payload named no repository still has a source")

# -- the notification a rule makes ---------------------------------------

(def note (dto/note-for {:when {:event "push"}
                           :to [:telegram]
                           :chat-id "-1001234567890"}
                          delivery push-payload))

(assert (= :hub/delivery (note :key)))
(assert (= [:telegram] (note :channels))
        "the rule decides the channels, not the call site")
(assert (= "-1001234567890" (get-in note [:to :telegram]))
        "and the address is keyed by what an address is (ADR-0040)")
(assert (= "ce4b1f00" (get-in note [:data :delivery]))
        "the delivery is on the notification, so a message can be traced back")
(assert (= "github/2026/09/ce4b1f00.json" (get-in note [:data :key]))
        "including where its bytes are kept")

(def unaddressed (dto/note-for {:to [:telegram]} delivery push-payload))
(assert (empty? (unaddressed :to))
        "a rule that names no chat leaves the channel to its configured one")

(print "hub route-test ok")
