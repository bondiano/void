(import ../test-support/paths)
(import void/auth/store :as store)

# -- the user store ------------------------------------------------------

(def users
  (store/normalize-user-store
    (store/memory-user-store
      {"user:1" {:subject "user:1" :email "a@b.c" :username "ann"
                 :password-hash "$scrypt$x" :claims {:role :admin}}
       "user:2" {:subject "user:2" :email "b@b.c" :password-hash nil}}
      [:email :username])))

(assert (= "user:1" (((users :find) {:by :subject :value "user:1"}) :subject)))
(assert (= "user:1" (((users :find) {:by :email :value "a@b.c"}) :subject)))
(assert (= "user:1" (((users :find) {:by :username :value "ann"}) :subject)))
(assert (nil? ((users :find) {:by :email :value "nobody@b.c"})))
(assert (nil? ((users :find) {:by :phone :value "555"})) "an index the store does not keep is simply not found")
(assert (= "user:1" (((users :find) {:value "user:1"}) :subject))
        "the default selector is :subject — a session carries one, and every store must answer it")

(def ann ((users :find) {:by :subject :value "user:1"}))
(assert (= "$scrypt$x" ((users :secret) ann)))
(assert (deep= {:role :admin} ((users :claims) ann)))
(assert (nil? ((users :secret) ((users :find) {:by :subject :value "user:2"})))
        "a user with no password has none — the password strategy then fails through dummy-verify")

# the fallbacks a minimal store gets
(def minimal (store/normalize-user-store {:find (fn [_] {:id 1}) :subject (fn [_] "x:1")}))
(assert (nil? ((minimal :secret) {})) "no :secret means nobody has a password")
(assert (empty? ((minimal :claims) {})))

(each bad [{} {:find (fn [_])} {:subject (fn [_])} "nope" nil]
  (def [ok] (protect (store/normalize-user-store bad)))
  (assert (not ok) (string/format "%q is not a user store" bad)))

# -- the token store -----------------------------------------------------

(def tokens (store/normalize-token-store (store/memory-token-store)))
((tokens :put) {:id "a" :digest "d1" :subject "user:1"})
((tokens :put) {:id "b" :digest "d2" :subject "user:1"})
((tokens :put) {:id "c" :digest "d3" :subject "user:2"})
(assert (= "d1" (((tokens :find) "a") :digest)))
(assert (= 2 (length ((tokens :list) "user:1"))))
(assert (nil? ((tokens :find) "missing")))
((tokens :touch) "a" 12345)
(assert (= 12345 (((tokens :find) "a") :used)))
(assert ((tokens :delete) "a"))
(assert (not ((tokens :delete) "a")) "deleting twice says so")

(def minimal-tokens
  (store/normalize-token-store {:find (fn [_]) :put (fn [_]) :delete (fn [_] false)}))
(assert (nil? ((minimal-tokens :touch) "x" 1)) "a store that will not write on every request just leaves :touch out")
(assert (empty? ((minimal-tokens :list) "user:1")))

# -- the challenge store -------------------------------------------------

(def codes (store/normalize-challenge-store (store/memory-challenge-store)))
((codes :put) "h1" {:digest "d" :subject "user:1"} 60)
(assert (= "user:1" (((codes :take) "h1") :subject)))
(assert (nil? ((codes :take) "h1"))
        "taken is taken — a code that can be read twice is not single-use")

((codes :put) "h2" {:digest "d"} -1)
(assert (nil? ((codes :take) "h2")) "an expired record is not handed over")

((codes :put) "h3" {:digest "d"} -1)
((codes :sweep))
(assert (nil? (get (get (store/memory-challenge-store) :rows) "h3")))

(each bad [{} {:put (fn [_ _ _])} "nope"]
  (def [ok] (protect (store/normalize-challenge-store bad)))
  (assert (not ok) (string/format "%q is not a challenge store" bad)))

(print "store-test ok")
