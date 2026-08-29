(import ../test-support/paths)
(import void/mail/message :as message)

(def cfg {:from "void <no-reply@example.com>"
          :subject-prefix "[void]"
          :headers {"x-app" "void"}})

(def m (message/normalize {:to "ada@example.com"
                           :cc ["cc@example.com"]
                           :bcc "audit@example.com"
                           :subject "hi"
                           :text "body"
                           :headers {"x-kind" "test"}}
                          cfg))

(assert (= "no-reply@example.com" (get-in m [:from :email])))
(assert (= "[void] hi" (m :subject)) "the prefix comes from the slice, not the call site")
(assert (deep= @["ada@example.com" "cc@example.com" "audit@example.com"] (m :recipients))
        "the envelope is to + cc + bcc")
(assert (= "void" (get-in m [:headers "x-app"])) "configured headers ride on every message")
(assert (= "test" (get-in m [:headers "x-kind"])) "and a message may add its own")
(assert (= "no-reply@example.com" (m :envelope-from))
        "bounces go to the sender until [:mail :envelope-from] says otherwise")

(def bounced (message/normalize {:to "a@b.co" :text "x" :subject "s"
                                 :envelope-from "bounces@example.com"}
                                cfg))
(assert (= "bounces@example.com" (bounced :envelope-from)))
(assert (= "no-reply@example.com" (get-in bounced [:from :email]))
        "and the From a person reads is a different thing from the Return-Path")

(assert (deep= @["a@b.co"] ((message/normalize {:to "a@b.co" :text "x" :subject "s"} cfg)
                            :recipients)))

# -- what it refuses -----------------------------------------------------

(each [msg reason]
  [[{:subject "s" :text "x"} "no recipients"]
   [{:to "a@b.co" :subject "s"} "neither :text nor :html"]
   [{:to "not-an-address" :subject "s" :text "x"} "a recipient that is not an address"]]
  (assert (not (first (protect (message/normalize msg cfg)))) reason))

(assert (not (first (protect (message/normalize {:to "a@b.co" :subject "s" :text "x"} {}))))
        "a message with no :from and no [:mail :from] is refused, rather than sent from a name void invented")

# -- the staging override ------------------------------------------------

(def redirected (message/normalize {:to ["ada@example.com" "grace@example.com"]
                                    :cc "cc@example.com"
                                    :subject "s" :text "x"}
                                   (merge cfg {:to-override "dev@example.com"})))
(assert (deep= @["dev@example.com"] (redirected :recipients))
        "every recipient is replaced, cc and bcc included")
(assert (= "ada@example.com, grace@example.com, cc@example.com"
           (get-in redirected [:headers "X-Void-Original-To"]))
        "and what would have happened is written into the message itself")

# -- the guard a transport leans on -------------------------------------

(assert (message/normalized? m))
(assert (not (message/normalized? {:to "a@b.co"})))
(assert (string/find "ada@example.com" (message/summary m)))
