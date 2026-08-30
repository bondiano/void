### void/admin/query — the state of a list, read out of the URL
### (ADR-0029 §6, §10).
###
### Filters, search, sorting and the page number live in the query
### string and nowhere else. That is what makes the back button work
### under htmx (`hx-push-url`), and it is also what makes the admin
### horizontally scalable: there is no server-side basket of "what the
### operator selected", so selecting on one replica and confirming on
### another is the same request either way (§10).
###
### **`:scope` narrows the query and the count with the same
### expression.** A count that ignored the scope would page over rows
### the operator cannot see; a scope applied after loading would page
### over rows it then threw away. Both are the same bug, and the fix
### is to build one where-clause and hand it to `query` and to `count`.
###
### The clause is built from the *entity's columns*, never from the
### keys the browser sent: a parameter names a declared filter or it
### is ignored. A filter panel that compiled arbitrary input into SQL
### would be a filter panel with an injection in it.

(import void/db :as db)
(import ./resource :as res)

(defn- qparam [req name]
  (def v (get-in req [:query name]))
  (when (and v (not (empty? (string v)))) (string v)))

(defn- column [desc fname]
  (keyword (get-in desc [:entity :fields fname :column])))

# -- value coercion ------------------------------------------------------

(defn coerce
  ``One query-string value -> a domain value, using the schema node the
  entity already carries. Unparseable input is not an error and not a
  guess: it is `nil`, and a nil filter is no filter. A filter panel is
  not a form, and refusing to draw a page because somebody edited the
  URL would be a denial of service with extra steps.``
  [field raw]
  (def s (string raw))
  (case (field :type)
    :int (let [n (scan-number s)] (when (and n (= n (math/trunc n))) (math/trunc n)))
    :number (scan-number s)
    :boolean (cond (= s "true") true (= s "false") false nil)
    :enum (let [k (keyword s)]
            (when (index-of k (get-in field [:node :props :values] [])) k))
    :uuid s
    s))

# -- the state -----------------------------------------------------------

(defn state
  ``The list state this request asks for: page, per-page, sort column
  and direction, the search term and the value of every declared
  filter. Nothing here trusts a name it was given — sorting happens on
  a `:sortable` column or not at all.``
  [desc req &opt opts]
  (default opts {})
  (def per-page
    (or (desc :per-page) (get opts :per-page) 25))
  (def page
    (max 1 (or (when-let [p (qparam req "page")] (scan-number p)) 1)))
  (def sort
    (when-let [s (qparam req "sort")]
      (def k (keyword s))
      (when (index-of k (desc :sortable)) k)))
  (def dir (if (= "asc" (qparam req "dir")) :asc :desc))
  (def filters @{})
  (each f (desc :filters)
    (def fd (f :field))
    # a range is two parameters and one filter — Django's date_hierarchy
    # without a second concept
    (def from (qparam req (string (f :param) "-from")))
    (def to (qparam req (string (f :param) "-to")))
    (def exact (qparam req (f :param)))
    (cond
      (or from to)
      (put filters (f :name) {:from (when from (coerce fd from))
                              :to (when to (coerce fd to))})
      exact
      (let [v (coerce fd exact)]
        (unless (nil? v) (put filters (f :name) {:eq v})))))
  {:page page
   :per-page per-page
   :offset (* (dec page) per-page)
   :sort sort
   :dir dir
   :q (qparam req "q")
   :filters (freeze filters)})

# -- the where clause ----------------------------------------------------

(defn- search-clause [desc term]
  (def pat (string "%" term "%"))
  (def cs (seq [c :in (desc :search)] [:like (column desc c) pat]))
  (case (length cs)
    0 nil
    1 (first cs)
    [:or ;cs]))

(defn- filter-clauses [desc st]
  (def out @[])
  (eachp [fname spec] (st :filters)
    (def col (column desc fname))
    (cond
      (not (nil? (get spec :eq))) (array/push out [:= col (spec :eq)])
      (do
        (when-let [v (get spec :from)] (array/push out [:>= col v]))
        (when-let [v (get spec :to)] (array/push out [:<= col v])))))
  out)

(defn where
  ``The one clause both `query` and `count` are given: the resource's
  `:scope` for this request, the declared filters that carry a value,
  and the search term. `extra` is folded in the same way — that is how
  an inline narrows to its parent and a bulk selection narrows to its
  identifiers, without a second code path.``
  [desc req st &opt extra]
  (def parts @[])
  (when-let [scope (desc :scope)]
    (when-let [c (scope req)] (array/push parts c)))
  (array/concat parts (filter-clauses desc st))
  (when-let [term (st :q)]
    (when-let [c (search-clause desc term)] (array/push parts c)))
  (when extra (array/push parts extra))
  (case (length parts)
    0 nil
    1 (first parts)
    [:and ;parts]))

(defn scoped
  ``The scope alone (plus `extra`) — what every single-row action reads
  through. A row outside the scope is not a 403 by accident: it is
  simply not found, and the policy on the loaded row is the second
  echelon behind it (ADR-0029 §3).``
  [desc req &opt extra]
  (where desc req {:filters {}} extra))

(defn order-by
  "The ORDER BY: the sortable column the URL asked for, else the
  resource's declared default."
  [desc st]
  (if-let [s (st :sort)]
    [[(column desc s) (st :dir)]]
    (tuple ;(seq [entry :in (desc :order-by)]
              (if (indexed? entry)
                [(column desc (entry 0)) (get entry 1 :asc)]
                [(column desc entry) :asc])))))

# -- reading -------------------------------------------------------------

(defn total
  "How many rows this list has under its scope and filters — counted
  with the very clause the page is about to select with."
  [desc req st &opt extra]
  (db/count (desc :entity) {:where (where desc req st extra)}))

(defn rows
  "One page of the list."
  [desc req st &opt extra]
  (db/query (desc :entity)
            (merge {:where (where desc req st extra)
                    :order-by (order-by desc st)
                    :limit (st :per-page)
                    :offset (st :offset)}
                   (if-let [p (desc :preload)] {:preload p} {}))))

(defn pk-field
  "The primary key's field descriptor — what a path parameter has to be
  coerced through before it reaches a query."
  [desc]
  (res/field-descriptor (desc :entity) (get-in desc [:entity :pk])))

(defn pk-value
  "A path parameter (always a string) as the primary key's own type."
  [desc raw]
  (coerce (pk-field desc) raw))

(defn find-scoped
  ``One row by primary key, inside the scope. Returns nil when the row
  does not exist *or* is not this subject's — the two are the same
  answer on purpose.``
  [desc req id]
  (def ent (desc :entity))
  (def key (pk-value desc id))
  (when (not (nil? key))
    (db/one ent
            (merge {:where (scoped desc req [:= (keyword (ent :pk-column)) key])}
                   (if-let [p (desc :preload)] {:preload p} {})))))

# -- selections ----------------------------------------------------------

(defn selection
  ``What a bulk action is about to touch, as data:

      {:all true  :where <clause>}     the whole filtered list
      {:ids [...] :where <clause>}     the identifiers that were ticked

  The count is never taken from the client. `?all=1` re-runs the
  filter on the server, and a list of identifiers is still intersected
  with the scope — a forged identifier selects a row the operator was
  never allowed to see, and that is exactly the request this narrows
  away.``
  [desc req st]
  (def ent (desc :entity))
  (def pkf (pk-field desc))
  (if (get-in req [:query "all"])
    {:all true :where (where desc req st)}
    (let [raw (or (get-in req [:form "ids"]) (get-in req [:query "ids"]) "")
          # a form with several ticked boxes sends the name repeatedly and
          # wire/parse-query accumulates an array; a link sends one
          # comma-joined value. Both are the same selection
          pieces (if (indexed? raw)
                   (mapcat |(string/split "," (string $)) raw)
                   (string/split "," (string raw)))
          ids (filter |(not (nil? $))
                      (map |(coerce pkf $)
                           (filter |(not (empty? $)) pieces)))]
      {:all false
       :ids (tuple ;ids)
       :where (if (empty? ids)
                # nothing selected must select nothing, not everything
                (where desc req st [:in (keyword (ent :pk-column)) []])
                (where desc req st [:in (keyword (ent :pk-column)) (tuple ;ids)]))})))

(defn selected-rows
  ``The rows a selection resolves to, one batch at a time — a bulk over
  forty thousand rows must not become forty thousand instances at once.

  Paged by the **primary key**, not by an offset. An action changes the
  rows it touches, and a row that stops matching the selection (a
  delete, or a filter on the very column the action writes) shifts
  every offset behind it: with `:offset` a bulk would skip rows, and
  without advancing it a bulk would loop on the same batch forever.
  A key cursor is behind the processed rows whether they still match or
  not, so both cases are one case.``
  [desc sel &opt limit after]
  (default limit 200)
  (def pk (keyword (get-in desc [:entity :pk-column])))
  (def where
    (if (nil? after)
      (sel :where)
      (if-let [w (sel :where)] [:and w [:> pk after]] [:> pk after])))
  (db/query (desc :entity)
            (merge {:where where
                    :order-by [[pk :asc]]
                    :limit limit}
                   (if-let [p (desc :preload)] {:preload p} {}))))

(defn selected-count
  "How many rows a selection resolves to — counted on the server, with
  the clause the apply step will use."
  [desc sel]
  (db/count (desc :entity) {:where (sel :where)}))
