### void/rest/pagination — pagination/sorting/filtering conventions
### (SPEC.md §5.2).
###
### One convention across every list endpoint, all of it plain data:
### `?page=2&per-page=50` for page-based pagination, `?sort=-created-at,
### total` for ordering (leading `-` is descending), `?filter[status]=
### paid` for filtering. `query-schema` builds the map-schema fragment
### for the paging keys — merge it into a route's :void.schema/query
### and the validation middleware coerces and bounds-checks the values
### before the handler runs. `params` then reads the (already coerced)
### query into {:page :per-page :offset :limit :sort :filters};
### `envelope` and `link-headers` shape the response side: a {:data
### :page} body plus an RFC 8288 Link header (first/prev/next/last).

(import void/http/errors :as errors)
(import void/http/ring :as ring)
(import void/http/wire :as wire)

(def defaults
  "Convention defaults: page 1, 25 per page, 100 max per page."
  {:page 1 :per-page 25 :max-per-page 100})

(defn query-schema
  ``The map-schema fragment for the paging keys — merge into a route's
  :void.schema/query (deep-merge does it from a group layer too):

      {:page     [:optional [:int {:min 1}]]
       :per-page [:optional [:int {:min 1 :max 100}]]
       :sort     [:optional :string]}

  opts: :max-per-page (100).``
  [&opt opts]
  (default opts {})
  {:page [:optional [:int {:min 1}]]
   :per-page [:optional [:int {:min 1 :max (get opts :max-per-page
                                                (defaults :max-per-page))}]]
   :sort [:optional :string]})

(defn- query-get [query k]
  (def v (or (get query k) (get query (string k))))
  (if (indexed? v) (first v) v))

(defn- to-int [v]
  (cond
    (number? v) (math/trunc v)
    (bytes? v) (scan-number (string v))
    nil))

(defn parse-sort
  ``Parse a sort expression into [[field dir] ...]:

      (parse-sort "-created-at,total")
      # [[:created-at :desc] [:total :asc]]

  With `allowed` (an indexed of field keywords) an unknown field aborts
  400 — the problem renderer turns that into problem+json.``
  [s &opt allowed]
  (if (or (nil? s) (empty? (string/trim (string s))))
    []
    (seq [part :in (string/split "," (string s))
          :let [t (string/trim part)]
          :when (not (empty? t))]
      (def [field dir]
        (if (string/has-prefix? "-" t)
          [(keyword (string/slice t 1)) :desc]
          [(keyword t) :asc]))
      (when (and allowed (nil? (index-of field allowed)))
        (errors/abort 400 (string/format "cannot sort by %q" field)))
      [field dir])))

(defn filters
  "The filter[...] query keys as a table: ?filter[status]=paid ->
  {:status \"paid\"}."
  [query]
  (def out @{})
  (eachp [k v] (or query {})
    (def s (string k))
    (when (and (string/has-prefix? "filter[" s)
               (string/has-suffix? "]" s))
      (def name (string/slice s 7 -2))
      (unless (empty? name)
        (put out (keyword name) (if (indexed? v) (first v) v)))))
  out)

(defn params
  ``Read the paging convention out of a request's query (validated or
  raw — string values are scanned):

      (pagination/params req {:allowed-sort [:created-at :total]})
      # {:page 2 :per-page 50 :offset 50 :limit 50
      #  :sort [[:created-at :desc]] :filters {:status "paid"}}

  opts: :per-page and :max-per-page override the defaults,
  :allowed-sort whitelists sort fields (violation aborts 400).``
  [req &opt opts]
  (default opts {})
  (def query (or (req :query) {}))
  (def max-pp (get opts :max-per-page (defaults :max-per-page)))
  (def page (max 1 (or (to-int (query-get query :page)) (defaults :page))))
  (def per-page
    (min max-pp
         (max 1 (or (to-int (query-get query :per-page))
                    (get opts :per-page (defaults :per-page))))))
  {:page page
   :per-page per-page
   :offset (* (dec page) per-page)
   :limit per-page
   :sort (parse-sort (query-get query :sort) (opts :allowed-sort))
   :filters (filters query)})

(defn pages
  "Total page count for a total row count."
  [total per-page]
  (max 1 (math/ceil (/ total per-page))))

(defn envelope
  ``The conventional list body: items under :data, paging under :page.

      (pagination/envelope items {:page 2 :per-page 50 :total 117})
      # {:data items :page {:page 2 :per-page 50 :total 117 :pages 3}}``
  [items paging]
  (def {:page page :per-page per-page :total total} paging)
  {:data items
   :page {:page page
          :per-page per-page
          :total total
          :pages (when total (pages total per-page))}})

(defn link-headers
  ``Add the RFC 8288 Link header (rel first/prev/next/last) for a paged
  listing to a response:

      (pagination/link-headers resp "/orders" {:page 2 :per-page 50 :total 117})

  Other query keys to keep go in opts :query.``
  [resp base paging &opt opts]
  (default opts {})
  (def {:page page :per-page per-page :total total} paging)
  (def last-page (pages (or total 0) per-page))
  (defn url [p]
    (string base "?"
            (wire/encode-query (merge (get opts :query {})
                                      {:page p :per-page per-page}))))
  (def links @[])
  (array/push links (string/format `<%s>; rel="first"` (url 1)))
  (when (> page 1)
    (array/push links (string/format `<%s>; rel="prev"` (url (dec page)))))
  (when (< page last-page)
    (array/push links (string/format `<%s>; rel="next"` (url (inc page)))))
  (array/push links (string/format `<%s>; rel="last"` (url last-page)))
  (ring/header resp "link" (string/join links ", ")))
