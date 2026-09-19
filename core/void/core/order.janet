### void/core/order — order as a graph of edges to named anchors.
###
### A contribution that has to run in a certain place says where
### relative to something with a name: `:after` and `:before` a named
### anchor the point declares (`:void.http/authenticated`), or a named
### neighbour. There is no number to pick, so two plugins cannot both
### pick 4000 and find out which ran first from a sort of their names,
### and a gap nobody reserved cannot run out.
###
### One sort serves every ordered list: HTTP middleware, the edge,
### lifecycle hooks, bus middleware — and, with no anchors at all, the
### "first answer wins" lists (error renderers, auth strategies, secret
### sources), where an edge says who is asked first and the rest follow
### by name.
###
### Where two nodes have no path between them their order is still
### fixed, and not by the order they came in: every node sits in the
### zone of the anchor it follows (or just before the anchor it
### precedes), and inside a zone anchors go first and nodes by name. So
### `:after A` reads "right after A", and the answer is the same
### whichever plugin was listed first.
###
### Every mistake is reported at once — duplicates, nodes placed
### nowhere, edges to names that do not exist or belong to a plugin
### the contributor does not require — and a cycle prints its path.

(import ./util :as util)

(defn edges
  {:params [(or :keyword [:keyword] :nil)] :ret [:keyword] :throws [:string]}
  ``The names one `:after`/`:before` value points at, as a tuple: nil
  is none, a keyword is one, a list is itself.

      (edges nil)       # => []
      (edges :a)        # => [:a]
      (edges [:a :b])   # => [:a :b]``
  [v]
  (cond
    (nil? v) []
    (keyword? v) [v]
    (and (indexed? v) (all keyword? v)) (tuple ;v)
    (errorf "an edge is a keyword or a list of keywords, got %q" v)))

(defn- quoted
  {:params [[:any] :string] :ret :string}
  "The names `%q`-quoted and joined by `sep`, in the order given."
  [names sep]
  (string/join (map |(string/format "%q" $) names) sep))

(defn edges-str
  {:params [OrderNode] :ret :string}
  ``A node's edges the way a person reads them — for `describe`, an
  explain line or an error; the empty string for a node with none.

      (edges-str {:name :x :after [:a :b] :before :c})
      # => "after :a, :b; before :c"``
  [node]
  (string/join
    (seq [[side v] :in [["after" (node :after)] ["before" (node :before)]]
          :let [es (edges v)]
          :unless (empty? es)]
      (string side " " (quoted es ", ")))
    "; "))

# -- messages ------------------------------------------------------------

(defn- from-str
  {:params [(or :keyword :nil)] :ret :string}
  "Where a node came from, for a message: its plugin, or nothing."
  [plugin]
  (if plugin (string/format " (from %q)" plugin) ""))

(defn- who
  {:params [:string OrderNode] :ret :string}
  "A node as a message names it: `middleware :x (from :p)`."
  [what node]
  (string/format "%s %q%s" what (node :name) (from-str (node :plugin))))

(def- phase-hint " (:phase was removed in ADR-0051)")

# -- checks --------------------------------------------------------------

(defn- duplicate-errors
  {:params [[OrderNode] {:keyword :number} :string] :ret @[:string]}
  "A node whose name another node, or an anchor, already has."
  [nodes anchor-index what]
  (def seen @{})
  (seq [n :in nodes
        :let [k (n :name)
              first-seen (in seen k)
              err (cond
                    (in anchor-index k)
                    (string/format "%s takes the name of an anchor" (who what n))
                    first-seen
                    (string/format "duplicate %s %q%s — already given%s"
                                   what k (from-str (n :plugin))
                                   (from-str (first-seen :plugin))))]
        :after (unless first-seen (put seen k n))
        :when err]
    err))

(defn- requires?
  {:params [:any :keyword :keyword] :ret :boolean}
  "Does plugin `p` require plugin `q` directly? `requires` maps a
  plugin to its manifest's `:requires` — a dictionary keyed by plugin,
  or a plain list of plugins."
  [requires p q]
  (def r (get requires p))
  (cond
    (dictionary? r) (truthy? (get r q))
    (indexed? r) (truthy? (index-of q r))
    false))

(defn- visible?
  {:params [{:keyword :any} OrderNode OrderNode] :ret :boolean}
  "May `node` point at `target`? Its own plugin's nodes, the point
  owner's, a directly required plugin's and nodes with no plugin are
  all in reach; a node with no plugin reaches everything."
  [ctx node target]
  (def p (node :plugin))
  (def q (target :plugin))
  (or (nil? p) (nil? q) (= p q) (= q (ctx :owner))
      (requires? (ctx :requires) p q)))

(defn- reference-error
  {:params [{:keyword :any} OrderNode :string :keyword] :ret :string?}
  "What is wrong with one edge of `node`, or nil: a name that is
  neither an anchor nor a node, or a node of a plugin out of reach."
  [ctx node dir ref]
  (def target (in (ctx :by-name) ref))
  (cond
    (in (ctx :anchor-index) ref) nil
    (nil? target)
    (string/format "%s: %s %q is unknown%s"
                   (who (ctx :what) node) dir ref
                   (util/suggest ref (ctx :candidates)))
    (or (nil? (ctx :requires)) (visible? ctx node target)) nil
    (string/format "%s: %s %q belongs to %q, which %q does not require"
                   (who (ctx :what) node) dir ref
                   (target :plugin) (node :plugin))))

(defn- reference-errors
  {:params [{:keyword :any} [OrderNode]] :ret @[:string]}
  "Every edge of every node that points nowhere it may."
  [ctx nodes]
  (seq [n :in nodes
        [dir v] :in [[":after" (n :after)] [":before" (n :before)]]
        ref :in (edges v)
        :let [err (reference-error ctx n dir ref)]
        :when err]
    err))

(defn- unplaced-error
  {:params [{:keyword :any} OrderNode] :ret :string}
  "The message for a node no edge ties to an anchor (or, with no
  anchors, to anything)."
  [ctx node]
  (def anchors (ctx :anchors))
  (string/format "%s is not placed: give it :after or :before %s%s"
                 (who (ctx :what) node)
                 (if (empty? anchors)
                   (string "another " (ctx :what))
                   (string "one of the anchors " (quoted anchors " ")))
                 (if (nil? (node :phase)) "" phase-hint)))

# -- the graph -----------------------------------------------------------

(defn- graph
  {:params [[:keyword] [OrderNode] {:keyword :any}]
   :ret {:succ @{:keyword @[:keyword]} :pred @{:keyword @[:keyword]}}}
  "The adjacency over known names: the anchors chained in their
  order, then every node's edges whose both ends exist (an unknown end
  is already an error)."
  [anchors nodes known]
  (def succ @{})
  (def pred @{})
  (defn link
    {:params [:keyword :keyword] :ret :any}
    "Record `a` runs before `b`, when both are known."
    [a b]
    (when (and (in known a) (in known b))
      (update succ a |(array/push (or $ @[]) b))
      (update pred b |(array/push (or $ @[]) a))))
  (map link anchors (drop 1 anchors))
  (each n nodes
    (each a (edges (n :after)) (link a (n :name)))
    (each b (edges (n :before)) (link (n :name) b)))
  {:succ succ :pred pred})

(defn- reach
  {:params [[:keyword] (fn [:keyword] [:keyword])] :ret @{:keyword :boolean}}
  "Every name reachable from `start` by `step`, `start` included —
  a walk that a cycle cannot trap."
  [start step]
  (def seen @{})
  (def queue (array ;start))
  (while (not (empty? queue))
    (def k (array/pop queue))
    (unless (in seen k)
      (put seen k true)
      (array/concat queue (step k))))
  seen)

(defn- placed
  {:params [[:keyword] {:succ :any :pred :any}] :ret @{:keyword :boolean}}
  "The names tied into the order: with anchors, everything an anchor
  reaches or that reaches an anchor; with none, every name on an
  edge."
  [anchors g]
  (if (empty? anchors)
    (tabseq [k :in (distinct [;(keys (g :succ)) ;(keys (g :pred))])] k true)
    (merge (reach anchors |(get (g :succ) $ []))
           (reach anchors |(get (g :pred) $ [])))))

(defn- topo-order
  {:params [[:keyword] @{:keyword @[:keyword]} :string]
   :ret @[:keyword] :throws [:string]}
  "The names in some order every edge agrees with: a depth-first walk,
  names visited sorted — or an error printing the cycle's path."
  [names succ what]
  (def order @[])
  (def state @{})
  (def path @[])
  (defn visit
    {:params [:keyword] :ret :any :throws [:string]}
    "Visit one name after everything it runs before, raising on a
    cycle back through :visiting."
    [k]
    (case (in state k)
      :done nil
      :visiting
      (errorf "%s order is a cycle: %s"
              what (quoted [;(array/slice path (index-of k path)) k] " -> "))
      (do
        (put state k :visiting)
        (array/push path k)
        (each s (sorted (get succ k [])) (visit s))
        (array/pop path)
        (put state k :done)
        (array/insert order 0 k))))
  (each k (sorted names) (visit k))
  order)

(defn- zones
  {:params [@[:keyword] {:keyword :number} {:succ :any :pred :any} {:keyword :boolean}]
   :ret @{:keyword :number}}
  "The tie-break zone of each name: an anchor's is its index; a node's
  the highest of its predecessors', else one less than the nearest
  anchor after it; a node placed nowhere has none. With no anchors,
  every placed node shares zone 0."
  [order anchor-index g placed]
  (if (empty? anchor-index)
    (tabseq [k :in order :when (in placed k)] k 0)
    (let [dmin @{}
          zone @{}]
      (each k (reverse order)
        (def below (keep |(in dmin $) (get (g :succ) k [])))
        (put dmin k (or (in anchor-index k)
                        (unless (empty? below) (min ;below)))))
      (each k order
        (def above (keep |(in zone $) (get (g :pred) k [])))
        (put zone k (or (in anchor-index k)
                        (unless (empty? above) (max ;above))
                        (when-let [d (in dmin k)] (dec d)))))
      zone)))

(defn- kahn
  {:params [@[:keyword] {:succ :any :pred :any} (fn [:keyword] :any)]
   :ret @[:keyword]}
  "Kahn's sort, taking the smallest `key` among the ready names at
  every step, so the order is fixed by the graph and the keys alone."
  [names g key]
  (def indeg (tabseq [k :in names] k (length (get (g :pred) k []))))
  (def ready (filter |(zero? (in indeg $)) names))
  (def out @[])
  (while (not (empty? ready))
    (def k (extreme |(< (key $0) (key $1)) ready))
    (array/remove ready (index-of k ready))
    (array/push out k)
    (each s (get (g :succ) k [])
      (put indeg s (dec (in indeg s)))
      (when (zero? (in indeg s))
        (array/push ready s))))
  out)

# -- sort ----------------------------------------------------------------

(defn sort
  {:params [[OrderNode] OrderOpts]
   :ret @[(or OrderNode {:name :keyword :anchor :boolean})]
   :throws [:string]}
  ``Order `nodes` — structs with a `:name`, optional `:after` and
  `:before` (see `edges`) and the `:plugin` that contributed them —
  around the point's anchors. Answers the nodes in order with each
  anchor in its place as `{:name a :anchor true}`.

  Options:
    :anchors   the point's named places, in order (each runs before
               the next); none makes a plain list
    :what      what a node is called in a message ("middleware")
    :owner     the plugin owning the point: its nodes are in every
               contributor's reach
    :requires  plugin -> its manifest's `:requires`: an edge may only
               point at an anchor, its own plugin's node, the owner's
               or a directly required plugin's; nil skips that check
               (an edge to a name nobody has is an error regardless)
    :unplaced  :error (default) — a node tied to no anchor is an
               error; :last — it goes after the placed ones, by name

  Every error is reported in one throw; a cycle is its own, printing
  its path.``
  [nodes &opt opts]
  (def opts (or opts {}))
  (def anchors (tuple ;(get opts :anchors [])))
  (def what (get opts :what "node"))
  (def anchor-index (tabseq [[i a] :pairs anchors] a i))
  (def by-name (tabseq [n :in (reverse nodes)] (n :name) n))
  (def candidates [;anchors ;(keys by-name)])
  (def known (tabseq [k :in candidates] k true))
  (def ctx {:what what :anchors anchors :anchor-index anchor-index
            :by-name by-name :candidates candidates
            :owner (opts :owner) :requires (opts :requires)})
  (def g (graph anchors nodes known))
  (def on-graph (placed anchors g))
  (def errors
    [;(duplicate-errors nodes anchor-index what)
     ;(reference-errors ctx nodes)
     ;(if (= :last (opts :unplaced))
        []
        (seq [n :in nodes :unless (in on-graph (n :name))]
          (unplaced-error ctx n)))])
  (unless (empty? errors)
    (errorf "%s order is broken:\n  - %s" what (string/join errors "\n  - ")))
  (def order (topo-order candidates (g :succ) what))
  (def zone (zones order anchor-index g on-graph))
  (defn key
    {:params [:keyword] :ret [:any]}
    "Kahn's tie-break: zone, anchors first, then the name."
    [k]
    [(get zone k math/inf) (if (in anchor-index k) 0 1) (string k)])
  (map |(if (in anchor-index $) {:name $ :anchor true} (in by-name $))
       (kahn order g key)))

# -- first answer wins ---------------------------------------------------

(defn reject-priority
  {:params [[{:name :keyword & r}] :string] :ret :nil :throws [:string]}
  ``Raise when any of `nodes` still carries `:priority`, naming each
  one: the "first answer wins" lists are ordered by edges now, and a
  number that silently stopped meaning anything would be worse than
  the boot failing over it.``
  [nodes what]
  (def stale (filter |(not (nil? ($ :priority))) nodes))
  (unless (empty? stale)
    (errorf "%s has :priority, which was removed in ADR-0051 — place it with :after/:before"
            (string/join (map |(string/format "%s %q" what ($ :name)) stale) ", ")))
  nil)

(defn first-wins
  {:params [[OrderNode] :string OrderOpts] :ret @[OrderNode] :throws [:string]}
  ``Order a "first answer wins" list — error renderers, authentication
  strategies, secret sources: a node an edge ties in goes by the
  graph, and the rest follow it by name. `opts` go to `sort` (a point
  with anchors passes `:anchors` and `:owner`); the anchors are left
  out of the answer, which is the nodes alone. A leftover `:priority`
  is an error (see `reject-priority`).

      (first-wins [{:name :b} {:name :z :before :y} {:name :y}] "source")
      # => [:z :y :b], as nodes``
  [nodes what &opt opts]
  (reject-priority nodes what)
  (filter |(not ($ :anchor))
          (sort nodes (merge (or opts {}) {:what what :unplaced :last}))))
