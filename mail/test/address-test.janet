(import ../test-support/paths)
(import void/mail/address :as address)

# -- what an application writes -----------------------------------------

(assert (= "ada@example.com" ((address/parse "ada@example.com") :email)))
(assert (deep= {:name "Ada Lovelace" :email "ada@example.com"}
               (address/parse "Ada Lovelace <ada@example.com>")))
(assert (deep= {:name "Ada" :email "ada@example.com"}
               (address/parse {:name "Ada" :email "ada@example.com"}))
        "the table form is the canonical one and passes through")
(assert (= "ada@example.com" ((address/parse "  <ada@example.com>  ") :email)))
(assert (= "Ada" ((address/parse "\"Ada\" <ada@example.com>") :name))
        "the quotes around a display name are syntax, not part of the name")
(assert (nil? ((address/parse "<ada@example.com>") :name))
        "and a message with no display name has none, rather than an empty one")

(assert (= "a@b.co, Ada <ada@b.co>"
           (address/format-list ["a@b.co" {:name "Ada" :email "ada@b.co"}])))
(assert (deep= @["a@b.co"] (address/emails "a@b.co")) "one address is a list of one")
(assert (empty? (address/list-of nil)))
(assert (= "b.co" (address/domain-of "a@b.co")))

# -- what it must refuse -------------------------------------------------

(each [value reason]
  [["a@b.c, d@e.f" "a comma-separated list is a list, not a string"]
   ["ada" "no domain"]
   ["a b@c.de" "a space in the local part"]
   ["a@@b.co" "two @"]
   ["адрес@пример.рф" "a non-ASCII address needs SMTPUTF8, which this client does not speak"]
   [{:name "Ada"} "an address without an :email"]
   [42 "not an address at all"]]
  (assert (not (first (protect (address/parse value)))) reason))

(assert (not (first (protect (address/header-value "a subject" "hi\nBcc: mallory@evil.example"))))
        "a newline in a header value is header injection and is refused where headers are written")
(assert (not (first (protect (address/format-address {:name "Ada\r\nBcc: x@y.z"
                                                      :email "a@b.co"}))))
        "including when it hides in a display name")

(assert (address/valid-email? "user@localhost")
        "a relay on the machine has recipients without a dot in them")
(assert (address/ascii? "plain"))
(assert (not (address/ascii? "привет")))
