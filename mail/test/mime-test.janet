(import ../test-support/paths)
(import void/mail/mime :as mime)
(import void/mail/message :as message)

# The whole wire format is a pure function of the message, which is why
# this suite compares strings: a missing CRLF is invisible in any other
# kind of test and fatal in every mail client.

# -- headers -------------------------------------------------------------

(assert (= "Subject: plain\r\n" (mime/header "Subject" (mime/header-text "plain")))
        "ASCII stays readable in the file")

(def encoded (mime/header-text "Привет"))
(assert (string/has-prefix? "=?UTF-8?B?" encoded) "and anything else becomes an encoded word")
(assert (string/has-suffix? "?=" encoded))

(def long-word (mime/encoded-word (string/repeat "привет " 20)))
(each line (string/split "\r\n" long-word)
  (assert (<= (length (string/trim line)) 76)
          "an encoded word is split so that no line runs past the limit"))
(assert (all |(not= 0x80 (band 0xc0 $)) (map |($ 10) (string/split "\r\n " long-word)))
        "and split on codepoint boundaries, never inside a UTF-8 sequence")

(def folded (mime/address-header "To" (seq [i :range [0 12]] (string "user" i "@example.com"))))
(each line (string/split "\r\n" folded)
  (assert (<= (length line) 78) "a long address list is folded at a comma"))
(assert (string/find "\r\n " folded) "and the continuation line starts with whitespace")

(assert (nil? (mime/address-header "Cc" [])) "an empty list produces no header at all")

# -- quoted-printable ----------------------------------------------------

(assert (= "plain text" (mime/quoted-printable "plain text")))
(assert (= "=D0=BF" (mime/quoted-printable "п")))
(assert (= "1 =3D 1" (mime/quoted-printable "1 = 1")))
(assert (= "a=20" (mime/quoted-printable "a "))
        "trailing whitespace is encoded, or a relay may trim it away")
(assert (= "a\r\nb" (mime/quoted-printable "a\nb")) "line endings become CRLF")

(def wrapped (mime/quoted-printable (string/repeat "x" 200)))
(each line (string/split "\r\n" wrapped)
  (assert (<= (length line) 76) "and no line goes past 76 octets"))
(assert (string/has-suffix? "=" (first (string/split "\r\n" wrapped)))
        "a wrapped line ends with the soft break")

# -- the text part nobody wrote -----------------------------------------

(assert (= "Hi\n\nSee the link (https://x.y/z) & more"
           (mime/text-of "<h1>Hi</h1><p>See <a href=\"https://x.y/z\">the link</a> &amp; more</p>"))
        "a link keeps its target: it is content, not markup")
(assert (= "" (mime/text-of "<style>p{color:red}</style>")) "style and script contribute nothing")

# -- the whole message ---------------------------------------------------

(def cfg {:from "void <no-reply@example.com>"})
(def simple (message/normalize {:to "ada@example.com" :subject "hi" :text "body"} cfg))
(def bytes (mime/render simple {:date 1756400000 :message-id "<id@example.com>"}))

(assert (string/find "Date: Thu, 28 Aug 2025 " bytes))
(assert (string/find "From: void <no-reply@example.com>\r\n" bytes))
(assert (string/find "To: ada@example.com\r\n" bytes))
(assert (string/find "Content-Type: text/plain; charset=UTF-8\r\n" bytes))
(assert (not (string/find "multipart" bytes)) "one part needs no multipart wrapper")

(def with-bcc (message/normalize {:to "ada@example.com" :bcc "audit@example.com"
                                  :subject "hi" :text "body"} cfg))
(def bcc-bytes (mime/render with-bcc {}))
(assert (not (string/find "audit@example.com" bcc-bytes))
        "a Bcc recipient is in the envelope and never in the headers — that is what Bcc means")
(assert (index-of "audit@example.com" (with-bcc :recipients))
        "and is still a recipient")

(def rich (message/normalize {:to "ada@example.com" :subject "hi"
                              :html "<p>hello</p>"} cfg))
(def rich-bytes (mime/render rich {:boundaries ["one" "two"]}))
(assert (string/find "multipart/alternative; boundary=\"=_void_one\"" rich-bytes))
(assert (string/find "Content-Type: text/plain" rich-bytes)
        "HTML alone still gets a text part — generated, but there (see the module docstring)")
(assert (string/find "hello" rich-bytes))

(def attached (message/normalize {:to "ada@example.com" :subject "hi" :text "see attached"
                                  :attachments [{:filename "report.csv" :type "text/csv"
                                                 :content "a,b\n1,2\n"}]}
                                 cfg))
(def attached-bytes (mime/render attached {:boundaries ["one" "two"]}))
(assert (string/find "multipart/mixed; boundary=\"=_void_two\"" attached-bytes))
(assert (string/find "Content-Disposition: attachment; filename=\"report.csv\"" attached-bytes))
(assert (string/find "Content-Transfer-Encoding: base64" attached-bytes))

# -- header injection, at the layer that writes headers -----------------

(assert (not (first (protect (mime/render (message/normalize
                                            {:to "ada@example.com"
                                             :subject "hi\r\nBcc: mallory@evil.example"
                                             :text "x"} cfg)))))
        "a subject carrying a header is refused where the header is written")
