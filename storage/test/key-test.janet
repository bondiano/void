# Keys are the whole address space of a store, and every one of them
# crosses a filesystem or a URL — so what a key may be is decided here,
# once, and both stores inherit it.

(import ../test-support/paths)
(import void/storage/key :as key)

# -- what a key is -------------------------------------------------------

(each good ["a" "a.png" "uploads/2026/09/abc.png" "a/b/c/d" "x-y_z.tar.gz"]
  (assert (key/valid? good) (string/format "%q is a key" good)))

(each [bad reason]
  [["" "empty"]
   ["/leading" "absolute"]
   ["a//b" "an empty segment"]
   ["a/./b" "a dot segment"]
   ["../etc/passwd" "a climbing segment"]
   ["a/../../b" "a climb in the middle"]
   ["a\\b" "a backslash, which is a separator on the other family of systems"]
   [(string "a\0b") "a NUL"]
   [(string/repeat "x" 513) "longer than the cap"]
   [:not-a-string "not a string"]]
  (assert (not (key/valid? bad)) (string reason " is not a key"))
  (def [ok err] (protect (key/check! bad)))
  (assert (not ok) (string reason " is refused by check!"))
  (assert (string? err) "with a message that says what a key is"))

# the cap is a byte count, and one byte under it passes
(assert (key/valid? (string/repeat "x" key/max-length)) "the cap itself is fine")

# -- filenames come from browsers ----------------------------------------

(assert (= "me.png" (key/sanitize-filename "me.png")))
(assert (= "me.png" (key/sanitize-filename "C:\\Users\\ada\\me.png"))
        "a client path keeps only its last segment")
(assert (= "me.png" (key/sanitize-filename "/tmp/me.png")))
(assert (= "a-b.png" (key/sanitize-filename "a b.png")) "a space becomes a dash")
(assert (= "a-b.png" (key/sanitize-filename "a   b.png")) "and a run becomes one dash")
(assert (= "file" (key/sanitize-filename "")) "something with no usable name still needs one")
(assert (= "file" (key/sanitize-filename "...")) "and so does one made of dots")
(assert (= "passwd" (key/sanitize-filename "../../etc/passwd"))
        "a filename cannot climb, because only the last segment survives")

(assert (= ".png" (key/extension "me.PNG")) "the extension is lowercased")
(assert (= "" (key/extension "README")) "no dot, no extension")
(assert (= "" (key/extension ".bashrc")) "a leading dot is a name, not an extension")

# -- generated keys ------------------------------------------------------

(def at (os/mktime {:year 2026 :month 8 :month-day 0 :hours 12} :utc))  # 2026-09-01

(def k (key/generate {:prefix "products" :filename "photo.JPG" :now at}))
(assert (string/has-prefix? "products/2026/09/" k)
        (string/format "a generated key carries its prefix and date: %q" k))
(assert (string/has-suffix? ".jpg" k) "and the original extension, lowercased")
(assert (key/valid? k) "and it is a key")

(assert (not= (key/generate {:now at}) (key/generate {:now at}))
        "two uploads of the same name in the same month do not collide")

(assert (string/has-prefix? "uploads/" (key/generate {}))
        "the default namespace is uploads/")

(assert (string/has-prefix? "a-b/" (key/generate {:prefix "a b" :now at}))
        "a prefix is data too — it is sanitized, not trusted")
(assert (string/has-prefix? "etc/passwd/" (key/generate {:prefix "../etc/passwd" :now at}))
        "including a prefix that tried to climb")

(printf "key-test: ok")
