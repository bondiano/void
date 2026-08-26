(import ../test-support/paths)
(import void/http/static :as static)

# -- fixtures ------------------------------------------------------------

(def dir (string (or (os/getenv "TMPDIR") "/tmp") "/void-static-" (os/time)))
(os/mkdir dir)
(spit (string dir "/hello.txt") "hello static world")
(spit (string dir "/index.html") "<h1>home</h1>")
(os/mkdir (string dir "/sub"))
(spit (string dir "/sub/app.js") "console.log(1)")

(defn- req [path &opt headers method]
  @{:method (or method :get) :path path :headers (or headers @{})})

# -- mime / helpers ------------------------------------------------------

(assert (= "text/javascript; charset=utf-8" (static/mime-type "a/b/app.js")))
(assert (= "application/octet-stream" (static/mime-type "noext")))
(assert (= "/a b" (static/path-decode "/a%20b")))
(assert (= (string dir "/x/y") (static/safe-join dir "x//y")))
(assert (nil? (static/safe-join dir "x/../../etc/passwd")) ".. is rejected")
(assert (nil? (static/safe-join dir "a\0b")) "NUL is rejected")

# -- file-response -------------------------------------------------------

(def ok (static/file-response (req "/hello.txt") (string dir "/hello.txt")))
(assert (= 200 (ok :status)))
(assert (= "hello static world" (string (ok :body))))
(assert (= "text/plain; charset=utf-8" (get-in ok [:headers "content-type"])))
(def tag (get-in ok [:headers "etag"]))
(assert (string/has-prefix? "\"" tag) "strong etag is quoted")

(def cached (static/file-response (req "/hello.txt" @{"if-none-match" tag})
                                  (string dir "/hello.txt")))
(assert (= 304 (cached :status)) "matching if-none-match -> 304")
(assert (nil? (cached :body)))

(assert (nil? (static/file-response (req "/nope") (string dir "/nope")))
        "missing file -> nil")
(assert (nil? (static/file-response (req "/sub") (string dir "/sub")))
        "directory -> nil")

# ranges
(def part (static/file-response (req "/hello.txt" @{"range" "bytes=0-4"})
                                (string dir "/hello.txt")))
(assert (= 206 (part :status)))
(assert (= "hello" (string (part :body))))
(assert (= "bytes 0-4/18" (get-in part [:headers "content-range"])))

(def tail (static/file-response (req "/hello.txt" @{"range" "bytes=-5"})
                                (string dir "/hello.txt")))
(assert (= "world" (string (tail :body))) "suffix range")

(def open-end (static/file-response (req "/hello.txt" @{"range" "bytes=13-"})
                                    (string dir "/hello.txt")))
(assert (= "world" (string (open-end :body))) "open-ended range")

(def beyond (static/file-response (req "/hello.txt" @{"range" "bytes=99-"})
                                  (string dir "/hello.txt")))
(assert (= 416 (beyond :status)))
(assert (= "bytes */18" (get-in beyond [:headers "content-range"])))

(def multi (static/file-response (req "/hello.txt" @{"range" "bytes=0-1,3-4"})
                                 (string dir "/hello.txt")))
(assert (= 200 (multi :status)) "multi-range ignored, whole file")

# -- wrap-static ---------------------------------------------------------

(def fallthrough @{:status 200 :body "handler"})
(def h (static/wrap-static (fn [_] fallthrough) {:root dir :prefix "/assets/"}))

(assert (= "console.log(1)" (string ((h (req "/assets/sub/app.js")) :body))))
(assert (= "<h1>home</h1>" (string ((h (req "/assets/")) :body)))
        "directory serves index.html")
(assert (= fallthrough (h (req "/assets/nope.css"))) "miss falls through")
(assert (= fallthrough (h (req "/other/x"))) "outside prefix falls through")
(assert (= fallthrough (h (req "/assets/hello.txt" nil :post)))
        "POST falls through")
(assert (= fallthrough (h (req "/assets/..%2F..%2Fetc%2Fpasswd")))
        "encoded traversal falls through")
(assert (= "hello static world"
           (string ((h (req "/assets/hello%2etxt")) :body)))
        "percent-encoded path decodes")

(print "static-test ok")
