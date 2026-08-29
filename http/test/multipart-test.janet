(import ../test-support/paths)
(import void/http/multipart :as multipart)

(assert (= "xyz" (multipart/boundary "multipart/form-data; boundary=xyz")))
(assert (= "a b" (multipart/boundary `multipart/form-data; boundary="a b"`)))
(assert (nil? (multipart/boundary "application/json")))
(assert (nil? (multipart/boundary "multipart/form-data")))
(assert (nil? (multipart/boundary nil)))

(def body
  (string "preamble junk\r\n"
          "--B\r\n"
          "Content-Disposition: form-data; name=\"title\"\r\n"
          "\r\n"
          "hello world\r\n"
          "--B\r\n"
          "Content-Disposition: form-data; name=\"tag\"\r\n\r\n"
          "a\r\n"
          "--B\r\n"
          "Content-Disposition: form-data; name=\"tag\"\r\n\r\n"
          "b\r\n"
          "--B\r\n"
          "Content-Disposition: form-data; name=\"file\"; filename=\"x.bin\"\r\n"
          "Content-Type: application/octet-stream\r\n"
          "\r\n"
          "\x00\x01binary\r\ndata\r\n"
          "--B--\r\n"))

(def parts (multipart/parse body "B"))
(assert (= 4 (length parts)))

(def [title tag1 tag2 file] parts)
(assert (= "title" (title :name)))
(assert (= "hello world" (title :value)))
(assert (nil? (title :filename)))

(assert (= "file" (file :name)))
(assert (= "x.bin" (file :filename)))
(assert (= "application/octet-stream" (file :content-type)))
(assert (= "\x00\x01binary\r\ndata" (file :value))
        "binary content with embedded CRLF survives")

(def fs (multipart/fields parts))
(assert (= "hello world" (fs "title")))
(assert (deep= @["a" "b"] (fs "tag")) "duplicate fields accumulate")
(assert (nil? (fs "file")) "file parts stay out of fields")

# malformed bodies error
(assert (not (first (protect (multipart/parse "no boundary here" "B")))))
(assert (not (first (protect (multipart/parse "--B\r\nunterminated" "B")))))

# empty form (terminator right away)
(assert (empty? (multipart/parse "--B--\r\n" "B")))


# -- building, and the round trip ----------------------------------------

(def enc (multipart/encode
           [{:name "title" :value "cat \"quoted\""}
            {:name "avatar" :filename "me png.png" :content-type "image/png"
             :value "\x89PNG\r\n\x1a\n"}]))
(assert (string/has-prefix? "multipart/form-data; boundary=" (enc :content-type))
        "an encoded body brings the content type that describes it")
(assert (string/find (enc :boundary) (enc :body)))

(def back (multipart/parse (enc :body) (enc :boundary)))
(assert (= 2 (length back)) "and the parser reads back what the encoder wrote — one format, one implementation")
(assert (= "cat \"quoted\"" ((first back) :value)) "a quote in a value survives the header quoting")
(def file (last back))
(assert (= "avatar" (file :name)))
(assert (= "me png.png" (file :filename)) "so does a space in a filename")
(assert (= "image/png" (file :content-type)))
(assert (= "\x89PNG\r\n\x1a\n" (file :value)) "and CRLF inside the bytes is not framing")
(def folded (multipart/fields back))
(assert (and (= 1 (length folded)) (= "cat \"quoted\"" (folded "title")))
        "fields still folds only the parts that are not files")

(assert (not= (multipart/new-boundary) (multipart/new-boundary))
        "a boundary is fresh per body")

(def disp (multipart/content-disposition "attachment; filename=\"report 2026.pdf\""))
(assert (= "attachment" (disp :type))
        "content-disposition is public because a response carries it too — this is a download, not a form part")
(assert (= "report 2026.pdf" (disp :filename)))

(print "multipart-test ok")
