### void/mail/message — a message is a table.
###
###     {:to "ada@example.com"
###      :subject "Your sign-in link"
###      :text "..." :html "..."}
###
### and nothing else is required, because everything else is either in
### the [:mail] slice (who it is from, what the subject is prefixed
### with, where dev mail is redirected to) or is minted at delivery
### (Date, Message-ID). There is no builder object: a message is data
### all the way to the socket, so it can be queued as an argument of a
### job (./jobs), compared in a test, and printed when something goes
### wrong.
###
### `normalize` is where a message meets the configuration, and it is
### the only place that decides anything: after it, ./mime is a pure
### rendering and ./smtp a pure transmission.
###
### Two of those decisions are worth naming:
###
### **The envelope is not the headers.** Recipients travel to the
### server in RCPT TO — `:bcc` is a recipient and not a header, which
### is the whole of what Bcc means. `:envelope-from` (the Return-Path
### bounces go to) defaults to the From address and can be set apart
### from it, because bounce handling belongs to the deployment and not
### to the message.
###
### **`[:mail :to-override]` exists and is loud.** A staging system
### that mails real customers is a story every team has; the override
### redirects every recipient to one address and writes the original
### ones into `X-Void-Original-To`, so what would have happened is
### visible in the mail itself.

(import ./address :as address)

(def defaults
  ``The [:mail] keys a message inherits when it does not say.

  There is no default `:from`: a mail with a made-up sender is worse
  than an application that refuses to start until somebody says who
  it is from.``
  {:from nil
   :reply-to nil
   :envelope-from nil
   :subject-prefix nil
   :headers {}
   :to-override nil})

(defn- normalize-attachment
  {:params [{:content :any & r}]
   :ret {:filename :string :content :any :type :string :inline :boolean}
   :throws [:string]}
  "One attachment, filled in with the defaults every attachment needs."
  [a]
  (unless (dictionary? a)
    (errorf "an attachment is a table {:filename :content :type}, got %q" a))
  (unless (get a :content)
    (errorf "attachment %q has no :content" (get a :filename)))
  {:filename (string (get a :filename "attachment"))
   :content (get a :content)
   :type (string (get a :type "application/octet-stream"))
   :inline (true? (get a :inline))})

(defn- subject-of
  {:params [{:subject :any & r} {:subject-prefix :string? & r}] :ret :string}
  "The message's subject with [:mail :subject-prefix] prepended, when
  the slice sets one."
  [msg cfg]
  (def raw (string (get msg :subject "")))
  (def prefix (get cfg :subject-prefix))
  (if (and prefix (not (empty? (string prefix))))
    (string prefix " " raw)
    raw))

(defn normalize
  {:params [{:from :any :to :any :cc :any :bcc :any :reply-to :any :subject :any
             :text :any :html :any :headers :any :attachments :any :envelope-from :any
             & r}
            (or :nil {:from :any :reply-to :any :envelope-from :any :subject-prefix :string?
                      :headers :any :to-override :string? & r})]
   :ret @{:from {:name :string? :email :string}
          :to @[{:name :string? :email :string}]
          :cc @[{:name :string? :email :string}]
          :bcc @[{:name :string? :email :string}]
          :reply-to @[{:name :string? :email :string}]
          :subject :string
          :text :string?
          :html :string?
          :headers (or :nil {:string :any})
          :attachments @[{:filename :string :content :any :type :string :inline :boolean}]
          :envelope-from :string
          :recipients @[:string]}
   :throws [:string]}
  ``A message plus the [:mail] slice, resolved into the value every
  layer below reads: addresses parsed, subject prefixed, headers
  merged, recipients collected into the envelope.

  Throws with the missing piece named — an unaddressed or unsigned
  message is a bug in the calling code, not a delivery failure to
  retry.``
  [msg &opt cfg]
  (default cfg {})
  (unless (dictionary? msg)
    (errorf "a message is a table, got %q" msg))
  (def from (or (get msg :from) (get cfg :from)
                (error (string "this message has no :from and [:mail :from] is not set "
                               "— say who mail from this application comes from"))))
  (def to (address/list-of (get msg :to)))
  (def cc (address/list-of (get msg :cc)))
  (def bcc (address/list-of (get msg :bcc)))
  (when (and (empty? to) (empty? cc) (empty? bcc))
    (error "this message has no recipients"))
  (unless (or (get msg :text) (get msg :html))
    (error "this message has neither :text nor :html"))
  (def override (get cfg :to-override))
  (def headers
    (merge (get cfg :headers {})
           (get msg :headers {})
           (if override
             {"X-Void-Original-To"
              (string/join (map |($ :email) [;to ;cc ;bcc]) ", ")}
             {})))
  (def sender (address/parse from))
  (def base
    @{:from sender
      :to (if override [(address/parse override)] to)
      :cc (if override [] cc)
      :bcc (if override [] bcc)
      :reply-to (address/list-of (or (get msg :reply-to) (get cfg :reply-to)))
      :subject (subject-of msg cfg)
      :text (when-let [t (get msg :text)] (string t))
      :html (when-let [h (get msg :html)] (string h))
      :headers headers
      :attachments (map normalize-attachment (get msg :attachments []))
      :envelope-from ((address/parse (or (get msg :envelope-from)
                                         (get cfg :envelope-from)
                                         from))
                      :email)})
  (put base :recipients (distinct (map |($ :email) [;(base :to) ;(base :cc) ;(base :bcc)])))
  base)

(defn normalized?
  {:params [:any] :ret :boolean :narrows :any}
  "Has this message been through `normalize`? What a transport asserts
  before it puts anything on a socket."
  [msg]
  (and (dictionary? msg)
       (dictionary? (get msg :from))
       (indexed? (get msg :recipients))))

(defn summary
  {:params [{:from :any :recipients :any :subject :any & r}] :ret :string}
  "One line about a message, for a log record or a CLI listing."
  [msg]
  (string/format "%s -> %s: %s"
                 (get-in msg [:from :email] "?")
                 (string/join (get msg :recipients []) ", ")
                 (get msg :subject "")))
