(import ../test-support/paths)
(import void/core/log :as log)
(import void/mail/message :as message)
(import void/mail/mime :as mime)
(import void/mail/transport :as transport)

(log/set-level! "void" :error)

(def cfg {:from "void <no-reply@example.com>"})
(defn- delivery [&opt to]
  (def m (message/normalize {:to (or to "ada@example.com") :subject "hi" :text "body"} cfg))
  {:message m :bytes (mime/render m {:message-id "<id@example.com>"})
   :id "<id@example.com>" :at 1756400000})

# -- the contract --------------------------------------------------------

(each [contribution reason]
  [[{:send (fn [_] nil)} "a transport without a name"]
   [{:name :x} "a transport that cannot send"]
   [{:name "x" :send (fn [_] nil)} "a name that is not a keyword"]]
  (assert (not (first (protect (transport/normalize contribution)))) reason))

(def normalized (transport/normalize {:name :x :send (fn [_] nil)}))
(assert (nil? (normalized :doc)) "the optional halves are filled in, not left missing")

# -- :memory -------------------------------------------------------------

(transport/clear!)
(def memory (transport/memory-transport))
(def receipt ((memory :send) (delivery)))
(assert (= :memory (receipt :transport)))
(assert (deep= @["ada@example.com"] (receipt :accepted)))
(assert (empty? (receipt :rejected)))
(assert (= 1 (length transport/outbox)))
(assert (string/find "Subject: hi" (get-in transport/outbox [0 :bytes])))

(set transport/keep-count 3)
(repeat 5 ((memory :send) (delivery)))
(assert (= 3 (length transport/outbox))
        "the outbox is bounded — a dev server that runs for a week must not grow one mail at a time")
(set transport/keep-count transport/default-keep)
(transport/clear!)
(assert (empty? transport/outbox))

# -- :file ---------------------------------------------------------------

(def dir (string (os/getenv "TMPDIR" "/tmp") "/void-mail-test-" (os/time)))
(def file ((transport/file-transport dir) :send))
(def file-receipt (file (delivery)))
(assert (= :file (file-receipt :transport)))
(assert (os/stat (file-receipt :path)) "the .eml is where the receipt says it is")
(assert (string/find "Subject: hi" (slurp (file-receipt :path)))
        "and it is the message, byte for byte — a .eml opens in a mail client")
(os/rm (file-receipt :path))
(os/rmdir dir)

# -- :log ----------------------------------------------------------------

(def logged (((transport/log-transport) :send) (delivery)))
(assert (= :log (logged :transport)))
(assert (deep= @["ada@example.com"] (logged :accepted))
        "a logged message reports the recipients it would have gone to — nothing is delivered, and the receipt does not pretend otherwise")
