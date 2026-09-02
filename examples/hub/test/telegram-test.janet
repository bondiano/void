### The telegram channel, against a bot API that is a void/http server
### in this process. A fake that answers with real status codes is the
### only counterpart that can prove two things at once: that the bytes
### going out are a request somebody else's code could read, and that
### the retry decision is made from what came back.
###
### `[:hub :telegram :api-base]` is what makes this possible, and it is
### not a test hook — it is the field a self-hosted bot API server
### needs anyway.
(import void/core/log :as log)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/notify :as notify)
(import void/test :as test)
(import spork/json)
(import spork/sh)
(import ../main :as main)
(import ../telegram :as telegram)

(def token "111111:test-token")

# -- the bot API ---------------------------------------------------------

(def calls @[])

(defn- api [req]
  (def body (json/decode (string (or (req :body) "{}")) true))
  (array/push calls {:path (req :path) :body body})
  # the chat decides the answer, so one server covers every branch of
  # the retry decision
  (case (string (get body :chat_id))
    "-100" (ring/text 200 (json/encode {:ok true :result {:message_id 7}}))
    "-403" (ring/text 403 (json/encode {:ok false :description "bot was kicked"}))
    "-429" (ring/text 429 (json/encode {:ok false :description "Too Many Requests"}))
    (ring/text 404 (json/encode {:ok false :description "chat not found"}))))

(def inst (server/start {:handler api :port "0" :idle-timeout 2}))
(def api-base (string "http://127.0.0.1:" (inst :port)))

# -- the composition -----------------------------------------------------

(def tmp (string (or (os/getenv "TMPDIR") "/tmp") "/hub-telegram-" (os/time)))
(sh/rm tmp)
(os/mkdir tmp)

(def opts
  (merge main/app
         {:profile :test
          :config {:env @{}
                   :cli {:http {:port 0}
                         :db {:migrations {:dir "db/migrations"}}
                         :db-sqlite {:path (string tmp "/hub.sqlite3")}
                         :storage {:local {:root (string tmp "/storage")}}
                         :hub {:telegram {:token token
                                          :chat-id "-100"
                                          :api-base api-base}}
                         # deliver on this fiber: what the queue does
                         # with the same payload is void/notify-jobs'
                         # business and its own suite's
                         :notify {:queue false}
                         :mail {:transport :memory}
                         :auth {:scrypt {:ln 10}}
                         :crypto {:kdf {:in-thread false}}
                         :dev {:netrepl {:enabled false}
                               :watch {:enabled false}}}}}))

(defn- note [chat]
  {:key :hub/delivery
   :title "bondiano/void — push by bondiano"
   :body "refs/heads/main · 1 commit · feat: hub"
   :to {:telegram chat}
   :channels [:telegram]})

(log/set-sinks! [(fn [_])])

# -- the text is a pure projection ---------------------------------------

(assert (= "a\nb" (telegram/text-of {:title "a" :body "b"})))
(assert (= "a" (telegram/text-of {:title "a"}))
        "a notification with nothing to add is one line")
(assert (= "a" (telegram/text-of {:title "a" :body ""})))

# -- and so is the retry decision ----------------------------------------

(assert (telegram/permanent? {:status 403}) "kicked out of a chat is final")
(assert (telegram/permanent? {:status 400}))
(assert (not (telegram/permanent? {:status 429})) "rate limiting is 'later'")
(assert (not (telegram/permanent? {:status 500})))
(assert (not (telegram/permanent? {:message "connection refused"}))
        "a connection that never got an answer has not had a final one")

(test/with-http [c (merge opts {:only [:http/kernel :crypto/lib
                                       :auth/registry :storage/store]})]

  # -- the delivery that goes through ------------------------------------
  (def result (notify/send (note "-100")))
  (def sent (first (result :results)))
  (assert (= :telegram (sent :channel)))
  (assert (= :sent (sent :status)) (string/format "expected :sent, got %q" sent))

  (def call (last calls))
  (assert (= (string "/bot" token "/sendMessage") (call :path))
          "the token is in the path, which is what the bot API wants")
  (assert (= "-100" (string (get-in call [:body :chat_id]))))
  (assert (= "bondiano/void — push by bondiano\nrefs/heads/main · 1 commit · feat: hub"
             (get-in call [:body :text]))
          "title, then whatever there was room to add")
  (assert (true? (get-in call [:body :disable_web_page_preview]))
          "a commit message full of links should not become a wall of previews")

  # -- the chat that threw the bot out -----------------------------------
  (def refused (notify/send (note "-403")))
  (assert (= :failed ((first (refused :results)) :status))
          "one channel's failure is a result, never an exception (ADR-0040)")

  # -- the address, and the one the configuration falls back to ----------
  # `:to {}` rather than no `:to` at all: void/notify insists a
  # notification be addressed even when the channel knows where it goes,
  # and an empty address table is how a rule that named no chat says
  # "wherever this channel is configured to go" (./route.janet)
  (def default-chat (notify/send {:key :hub/delivery
                                  :title "no chat named"
                                  :to {}
                                  :channels [:telegram]}))
  (assert (= :sent ((first (default-chat :results)) :status))
          "a notification that names no chat goes to [:hub :telegram :chat-id]")
  (assert (= "-100" (string (get-in (last calls) [:body :chat_id])))))

(server/stop inst)
(sh/rm tmp)
(log/set-sinks! nil)
(print "hub telegram-test ok")
