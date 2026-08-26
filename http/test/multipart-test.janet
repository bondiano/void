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

(print "multipart-test ok")
