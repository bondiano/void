### void/mail/mime — a message as bytes (RFC 5322, 2045-2047).
###
### A pure projection: message data in, the octets of a mail out. No
### socket, no clock and no randomness that is not handed in — so the
### whole wire format is testable by comparing strings, which is the
### only way anybody ever finds a missing CRLF.
###
### Three choices worth knowing about:
###
### **Quoted-printable, not base64, for text.** Base64 is two lines of
### code and hides the message from everything that has to look at one:
### `less` on a stored .eml, a grep in a log, a human reading a bug
### report. QP keeps a mail that is mostly ASCII mostly readable, and
### it is the encoding that enforces the line limit SMTP actually has
### (RFC 5321 §4.5.3.1: 1000 octets, and this stays under 76).
###
### **The text part is generated when the caller gives only HTML.**
### A generated plain-text part is a poor rendering of the HTML; a
### message without one is a message that spam filters distrust and
### that a text-only client cannot show at all. The projection is
### deliberately simple and it is public (`text-of`) — an application
### that wants a good text part writes one, and then nothing is
### generated.
###
### **Attachments are `multipart/mixed` only.** Inline images
### (`multipart/related` + Content-ID) are not here: they need a second
### nesting level and a cid-rewriting pass over the HTML, and a mail
### client that fetches an https:// image does the same job. Adding
### them later adds a level; it does not change what is written here.

(import spork/base64)
(import ./address :as address)

(def crlf "\r\n — the only line ending in a mail." "\r\n")

(def max-line
  "Longest line this module writes, encoded. RFC 5322 §2.1.1 wants 78
  including the CRLF; the hard limit below in SMTP is 1000."
  76)

# -- RFC 2047 encoded words ----------------------------------------------

(defn- utf8-chunks
  ``Split bytes into pieces of at most `n` octets, never inside a
  UTF-8 sequence: a continuation byte (10xxxxxx) is not a boundary,
  and a chunk that ended on one would decode to a replacement
  character in every client.``
  [s n]
  (def out @[])
  (var start 0)
  (def len (length s))
  (while (< start len)
    (var end (min len (+ start n)))
    (while (and (> end start) (< end len) (= 0x80 (band 0xc0 (s end))))
      (-- end))
    (array/push out (string/slice s start end))
    (set start end))
  out)

(defn encoded-word
  ``One header value as RFC 2047 encoded words (UTF-8, base64), split
  so that no line exceeds `max-line`. 45 octets of input make 60
  characters of base64, and `=?UTF-8?B??=` costs 12 more.``
  [value]
  (string/join (map |(string "=?UTF-8?B?" (base64/encode $) "?=")
                    (utf8-chunks (string value) 45))
               (string crlf " ")))

(defn header-text
  ``A header value, encoded if it has to be. ASCII stays as it is —
  the common case must stay readable in the file — and anything else
  becomes encoded words.``
  [value]
  (def s (string value))
  (if (address/ascii? s) s (encoded-word s)))

(defn- fold
  ``Fold a long header value at ", " boundaries (RFC 5322 §2.2.3). Only
  address lists get long enough to need it, and they are the values
  that have a legal place to break.``
  [value]
  (def parts (string/split ", " value))
  (var line (buffer))
  (def lines @[])
  (each part parts
    (when (and (not (empty? line))
               (> (+ (length line) 2 (length part)) max-line))
      (array/push lines (string line))
      (buffer/clear line))
    (unless (empty? line) (buffer/push line ", "))
    (buffer/push line part))
  (array/push lines (string line))
  (string/join lines (string crlf " ")))

(defn header
  ``One header line, `name: value` — the value checked for the newline
  that would inject another header, encoded if it is not ASCII, and
  folded if it is long.

  The check comes **before** the encoding on purpose. An encoded word
  would carry a CR harmlessly (it is base64 by then, and no client
  turns it back into a header), so encoding first would mean silently
  accepting a subject nobody meant to write. A control character in a
  header is a bug in the caller, and this is where it is visible.``
  [name value]
  (def clean (address/header-value (string "header " name) value))
  (string name ": " (fold (header-text clean)) crlf))

(defn address-header
  "A header holding one or more addresses, with display names encoded."
  [name addrs]
  (def rendered
    (string/join
      (seq [a :in (address/list-of addrs)]
        (if-let [n (a :name)]
          (string (header-text (address/header-value "a display name" n))
                  " <" (a :email) ">")
          (a :email)))
      ", "))
  # the display names are encoded already; `header` sees ASCII and
  # leaves it alone
  (unless (empty? rendered) (header name rendered)))

# -- transfer encodings --------------------------------------------------

(defn- hex-octet [b]
  (string/format "=%02X" b))

(defn quoted-printable
  ``Encode bytes as quoted-printable (RFC 2045 §6.7): printable ASCII
  stays, everything else becomes =XX, trailing whitespace is escaped
  so that no relay can trim it away, and lines are broken with a soft
  `=` before they reach the limit.``
  [data]
  (def s (string/replace-all "\r\n" "\n" (string data)))
  (def lines @[])
  (def line @"")
  (defn hard-break [] (array/push lines (string line)) (buffer/clear line))
  (defn soft-break [] (array/push lines (string line "=")) (buffer/clear line))
  (defn emit [piece]
    # -1 leaves room for the soft-break '=' that would follow
    (when (> (+ (length line) (length piece)) (dec max-line)) (soft-break))
    (buffer/push line piece))
  (def len (length s))
  (for i 0 len
    (def b (s i))
    (def eol? (or (= i (dec len)) (= 0x0a (s (inc i)))))
    (cond
      (= 0x0a b) (hard-break)
      # whitespace at the end of a line has to be encoded: a relay that
      # strips it would change the body under a signature
      (and (or (= 0x20 b) (= 0x09 b)) eol?) (emit (hex-octet b))
      (or (= 0x20 b) (= 0x09 b)) (emit (string/from-bytes b))
      (= 0x3d b) (emit (hex-octet b))
      (and (>= b 0x21) (<= b 0x7e)) (emit (string/from-bytes b))
      (emit (hex-octet b))))
  (array/push lines (string line))
  (string/join lines crlf))

(defn base64-body
  "Base64 with the line length a mail body is allowed (RFC 2045 §6.8)."
  [data]
  (def encoded (base64/encode (string data)))
  (string/join
    (seq [i :range [0 (length encoded) max-line]]
      (string/slice encoded i (min (length encoded) (+ i max-line))))
    crlf))

# -- the plain-text part nobody wrote ------------------------------------

(def- tag-peg
  (peg/compile ~(* "<" (any (if-not ">" 1)) ">")))

(defn text-of
  ``A plain-text rendering of an HTML body — what goes in the text part
  when the caller gave only HTML (see the module docstring on why
  something is generated at all).

  Deliberately simple: block tags become line breaks, links keep their
  href in parentheses, everything else loses its markup and its
  entities are unescaped. It is a fallback, not a converter.``
  [html]
  (var s (string html))
  (set s (peg/replace-all ~(* "<" (+ "script" "style") (any (if-not ">" 1)) ">"
                              (any (if-not "</" 1))
                              "</" (+ "script" "style") (any (if-not ">" 1)) ">")
                          "" s))
  # a link is the one piece of markup whose target is content
  (set s (peg/replace-all ~(* "<a" :s+ (any (if-not (+ "href" ">") 1))
                              "href" (any :s) "=" (any :s) (set "\"'")
                              (<- (any (if-not (set "\"'") 1)))
                              (set "\"'") (any (if-not ">" 1)) ">"
                              (<- (any (if-not "<" 1)))
                              "</a>")
                          (fn [_ href text] (string text " (" href ")"))
                          s))
  (each [pattern replacement]
        [[~(* "<" (? "/") (+ "p" "div" "tr" "li" "h1" "h2" "h3" "h4" "h5" "h6"
                            "table" "ul" "ol" "blockquote" "section" "article")
              (any (if-not ">" 1)) ">") "\n"]
         [~(* "<br" (any (if-not ">" 1)) ">") "\n"]]
    (set s (peg/replace-all pattern replacement s)))
  (set s (peg/replace-all tag-peg "" s))
  (each [entity char] [["&nbsp;" " "] ["&amp;" "&"] ["&lt;" "<"] ["&gt;" ">"]
                       ["&quot;" "\""] ["&#39;" "'"] ["&apos;" "'"]]
    (set s (string/replace-all entity char s)))
  # collapse the blank lines the block rules leave behind
  (def lines (map string/trim (string/split "\n" s)))
  (def out @[])
  (each line lines
    (unless (and (empty? line) (or (empty? out) (empty? (last out))))
      (array/push out line)))
  (string/trim (string/join out "\n")))

# -- the message ---------------------------------------------------------

(defn date-header
  ``An RFC 5322 date, in UTC. A local offset would need a timezone
  database Janet does not have, and `+0000` is not a lie — it is where
  the process thinks it is.``
  [time]
  # (os/date t) is UTC; the second argument would ask for local time,
  # and :month / :month-day are zero-based (Janet, not RFC 5322)
  (def d (os/date time))
  (def days ["Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"])
  (def months ["Jan" "Feb" "Mar" "Apr" "May" "Jun"
               "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"])
  (string/format "%s, %02d %s %d %02d:%02d:%02d +0000"
                 (days (d :week-day)) (inc (d :month-day)) (months (d :month))
                 (d :year) (d :hours) (d :minutes) (d :seconds)))

(defn message-id
  "A Message-ID from a random token and the sender's domain."
  [token domain]
  (string "<" token "@" domain ">"))

(defn boundary
  "A multipart boundary from a random token — prefixed so it cannot
  collide with anything a body says about void."
  [token]
  (string "=_void_" token))

(defn- part [content-type encoded-body encoding &opt extra]
  (string "Content-Type: " content-type crlf
          "Content-Transfer-Encoding: " encoding crlf
          (or extra "")
          crlf
          encoded-body crlf))

(defn- text-part [body]
  (part "text/plain; charset=UTF-8" (quoted-printable body) "quoted-printable"))

(defn- html-part [body]
  (part "text/html; charset=UTF-8" (quoted-printable body) "quoted-printable"))

(defn- attachment-part [a]
  (def filename (address/header-value "an attachment filename"
                                      (get a :filename "attachment")))
  (part (string (get a :type "application/octet-stream")
                "; name=\"" (header-text filename) "\"")
        (base64-body (get a :content ""))
        "base64"
        (string "Content-Disposition: "
                (if (get a :inline) "inline" "attachment")
                "; filename=\"" (header-text filename) "\"" crlf)))

(defn- multipart [subtype bound parts]
  (string "Content-Type: multipart/" subtype "; boundary=\"" bound "\"" crlf
          crlf
          "This is a message in MIME format." crlf
          (string/join (map |(string "--" bound crlf $) parts) "")
          "--" bound "--" crlf))

(defn body-of
  ``The MIME body of a message: the parts, their nesting and the
  Content-Type header that describes them, as one string.

  `bounds` supplies the boundary strings (one per nesting level) so
  that this stays a function of its arguments — a test compares
  bytes, and randomness would have to be reached around.``
  [msg bounds]
  (def text (or (msg :text) (when (msg :html) (text-of (msg :html)))))
  (def html (msg :html))
  (def attachments (get msg :attachments []))
  (def alternative
    (if html
      (if text
        (multipart "alternative" (bounds 0) [(text-part text) (html-part html)])
        (html-part html))
      (text-part (or text ""))))
  (if (empty? attachments)
    alternative
    (multipart "mixed" (bounds 1)
               [alternative ;(map attachment-part attachments)])))

(defn render
  ``A normalized message (see ./message) as the octets of a mail.

  `opts` carries what the message cannot know about itself:
  `:boundaries` (two tokens), `:message-id` and `:date`.``
  [msg &opt opts]
  (default opts {})
  (def bounds (map boundary (get opts :boundaries ["a" "b"])))
  (def headers @"")
  (defn add [line] (when line (buffer/push headers line)))
  (add (header "Date" (date-header (get opts :date (os/time)))))
  (add (address-header "From" (msg :from)))
  (add (address-header "To" (get msg :to [])))
  (add (address-header "Cc" (get msg :cc [])))
  (add (address-header "Reply-To" (get msg :reply-to [])))
  # Bcc is deliberately absent: the recipients are in the envelope
  # (RCPT TO), and a Bcc header would tell every recipient who else
  # got the message — which is the one thing Bcc means not to do
  (add (header "Subject" (get msg :subject "")))
  (when-let [id (or (get opts :message-id) (get msg :message-id))]
    (add (header "Message-ID" id)))
  (eachp [name value] (get msg :headers {})
    (add (header (string name) value)))
  (add (header "MIME-Version" "1.0"))
  (string headers (body-of msg bounds)))
