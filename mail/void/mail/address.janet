### void/mail/address — an address, and the header it is written into
### (RFC 5322 §3.4).
###
### Two things happen here, and the second is the reason this is a
### module rather than three lines in ./mime:
###
###   1. An address is **data** — `{:name "Ada" :email "ada@example.com"}`
###      — and a string is a shorthand for it. Every other spelling
###      ("Ada <ada@example.com>") is a rendering of the data, produced
###      here and nowhere else.
###
###   2. **A list of addresses is a list**, never a comma-separated
###      string. "a@b.c, Ada <ada@b.c>" is refused with an explanation:
###      splitting it correctly means parsing quoted display names, and
###      a parser that is wrong once puts a recipient nobody named on a
###      message somebody already sent.
###
### Everything that ends up in a header goes through `header-value`,
### which refuses CR and LF. That is not defence in depth, it is *the*
### defence: a newline in a subject or in a display name is how a
### header injection adds `Bcc:` to somebody else's mail, and the only
### place to stop it is the one place that writes headers.
###
### Non-ASCII **display names** are fine — they travel as RFC 2047
### encoded words (./mime). Non-ASCII **addresses** are refused: they
### need SMTPUTF8 (RFC 6531), which this client does not advertise, and
### a message the server accepts and then cannot deliver is worse than
### one refused here.

(def- local-peg
  (peg/compile
    ~{:atext (+ :w (set "!#$%&'*+/=?^_`{|}~-"))
      :atom (some :atext)
      :main (* :atom (any (* "." :atom)) -1)}))

(def- domain-peg
  (peg/compile
    ~{:label (* (+ :w) (any (+ :w (set "-"))))
      :main (* :label (any (* "." :label)) -1)}))

(defn ascii?
  "True when every byte is printable US-ASCII (space through ~)."
  [s]
  (all |(and (>= $ 0x20) (< $ 0x7f)) (string s)))

(defn valid-email?
  ``Is this an address this client can put in a MAIL FROM or an RCPT
  TO? Deliberately not the full RFC 5321 grammar: quoted local parts
  and address literals (`[192.0.2.1]`) are legal and are refused,
  because accepting them here would mean carrying their escaping
  through every layer below for the sake of addresses no application
  types.``
  [email]
  (def s (string email))
  (def at (string/find "@" s))
  (and (ascii? s)
       at
       (pos? at)
       # exactly one @ — the last one is the separator only in the
       # quoted-local-part grammar we just refused
       (nil? (string/find "@" s (inc at)))
       (peg/match local-peg (string/slice s 0 at))
       (peg/match domain-peg (string/slice s (inc at)))
       true))

(defn parse
  ``An address as data. Accepts what an application writes:

      "ada@example.com"
      "Ada Lovelace <ada@example.com>"
      {:name "Ada Lovelace" :email "ada@example.com"}

  and returns `{:name name-or-nil :email email}`. Throws on anything
  that is not an address — including a comma-separated list, which is
  a list and has to be written as one.``
  [addr]
  (cond
    (dictionary? addr)
    (let [email (string (or (get addr :email)
                            (errorf "an address needs an :email, got %q" addr)))]
      (unless (valid-email? email)
        (errorf "%q is not an address this client can send to" email))
      {:name (when-let [n (get addr :name)] (string n)) :email email})

    (bytes? addr)
    (let [s (string/trim (string addr))]
      (when (string/find "," s)
        (errorf (string "%q looks like several addresses in one string. A list of "
                        "addresses is a list: [\"a@b.c\" \"d@e.f\"]")
                s))
      (if (string/has-suffix? ">" s)
        (let [open (last (string/find-all "<" s))]
          (unless open (errorf "%q has no opening < for its closing >" s))
          (parse {:name (let [n (string/trim (string/slice s 0 open) " \t\"")]
                          (unless (empty? n) n))
                  :email (string/trim (string/slice s (inc open) -2))}))
        (parse {:email s})))

    (errorf "an address is a string or a {:name :email} table, got %q" addr)))

(defn list-of
  ``Normalize whatever a message put in :to / :cc / :bcc into a list of
  parsed addresses. nil is an empty list; one address is a list of
  one.``
  [addrs]
  (cond
    (nil? addrs) []
    (or (dictionary? addrs) (bytes? addrs)) [(parse addrs)]
    (indexed? addrs) (map parse addrs)
    (errorf "a recipient list is a string, an address or an array of them, got %q" addrs)))

(defn header-value
  ``A value on its way into a header, checked. CR and LF are refused —
  that is header injection, and this is the one place that can see
  it.``
  [what value]
  (def s (string value))
  (when (or (string/find "\r" s) (string/find "\n" s))
    (errorf "%s contains a newline, which would inject a header: %q" what s))
  s)

(defn format-address
  ``Render one parsed address for a header. The display name is not
  encoded here — ./mime does that, because whether an encoded word is
  needed depends on the whole header line, not on this piece.``
  [addr]
  (def a (parse addr))
  (if-let [name (a :name)]
    (string (header-value "a display name" name) " <" (a :email) ">")
    (a :email)))

(defn format-list
  "Render a list of addresses as one header value."
  [addrs]
  (string/join (map format-address (list-of addrs)) ", "))

(defn emails
  "Just the addresses — what SMTP puts in RCPT TO."
  [addrs]
  (map |($ :email) (list-of addrs)))

(defn domain-of
  "The domain half of an address, for a Message-ID."
  [addr]
  (def email ((parse addr) :email))
  (string/slice email (inc (string/find "@" email))))
