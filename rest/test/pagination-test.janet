(import ../test-support/paths)
(import void/rest/pagination :as pagination)

# -- sort parsing --------------------------------------------------------

(assert (deep= [] (pagination/parse-sort nil)))
(assert (deep= [] (pagination/parse-sort "  ")))
(assert (deep= @[[:created-at :desc] [:total :asc]]
               (pagination/parse-sort "-created-at,total")))
(assert (deep= @[[:a :asc]] (pagination/parse-sort " a , ")))

# whitelist violations abort with an http status
(def [ok err] (protect (pagination/parse-sort "-hacky" [:created-at])))
(assert (not ok))
(assert (= 400 (err :http/status)))

# -- filters -------------------------------------------------------------

(assert (deep= @{:status "paid" :brand "acme"}
               (pagination/filters @{"filter[status]" "paid"
                                     "filter[brand]" "acme"
                                     "page" "2"
                                     "filter[]" "junk"})))

# -- params --------------------------------------------------------------

(def p (pagination/params
         @{:query @{"page" "3" "per-page" "50" "sort" "-created-at"
                    "filter[status]" "paid"}}))
(assert (= 3 (p :page)))
(assert (= 50 (p :per-page)))
(assert (= 100 (p :offset)))
(assert (= 50 (p :limit)))
(assert (deep= @[[:created-at :desc]] (p :sort)))
(assert (deep= @{:status "paid"} (p :filters)))

# defaults and clamping
(def d (pagination/params @{:query @{}}))
(assert (= 1 (d :page)))
(assert (= 25 (d :per-page)))
(assert (= 0 (d :offset)))
(def clamped (pagination/params @{:query @{"per-page" "9000" "page" "0"}}))
(assert (= 100 (clamped :per-page)))
(assert (= 1 (clamped :page)))

# keyword keys (the validation middleware keywordizes+coerces) work too
(def kw (pagination/params @{:query @{:page 2 :per-page 10}}))
(assert (= 2 (kw :page)))
(assert (= 10 (kw :offset)))

# -- envelope and link headers -------------------------------------------

(def env (pagination/envelope [:a :b] {:page 2 :per-page 50 :total 117}))
(assert (deep= [:a :b] (env :data)))
(assert (= 3 (get-in env [:page :pages])))
(assert (= 117 (get-in env [:page :total])))

(def resp (pagination/link-headers @{:status 200 :headers @{}}
                                   "/orders" {:page 2 :per-page 50 :total 117}))
(def link (get-in resp [:headers "link"]))
(assert (string/find `rel="first"` link))
(assert (string/find `rel="prev"` link))
(assert (string/find `rel="next"` link))
(assert (string/find `rel="last"` link))
(assert (string/find "page=3" link))
(assert (string/find "page=1" link))

# first page has no prev
(def first-page (pagination/link-headers @{:status 200 :headers @{}}
                                         "/orders" {:page 1 :per-page 50 :total 60}))
(assert (nil? (string/find `rel="prev"` (get-in first-page [:headers "link"]))))

(print "pagination-test: ok")
