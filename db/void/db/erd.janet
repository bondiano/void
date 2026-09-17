### void/db/erd — entity registry -> ER diagram (wave-2
### exit criterion 3).
###
### `:db/rels` and `:db/fk` are the single source of truth for the
### preload planner, admin relation widgets and migrations-diff — the
### diagram is one more projection of the same declarations, never a
### hand-maintained picture that drifts. Output is Mermaid
### (erDiagram), which renders in GitHub, the docs site and the void
### admin without a toolchain.

(import ./entity :as entity)
(import ./builder :as builder)

(defn- column-type
  {:params [{:db/type :any & r}] :ret :string}
  ``The SQL a field's `:db/type` names. An entity written by `void make`
  declares the builder's portable keyword — the same one its migration
  wrote — so the diagram says `text` where the migration said `:text`,
  and a hand-written entity that spelled the engine's own type keeps
  it. A field with no `:db/type` at all shows as a value.``
  [f]
  (def t (get f :db/type))
  (cond
    (nil? t) "value"
    (keyword? t) (get builder/ansi-types t (string t))
    (string t)))

(defn- field-line
  {:params [{:fields {:keyword {:column :string :db/pk :boolean? :db/fk (or :keyword :nil) :db/unique :boolean? :db/type :any & r} & r} & r}
            :keyword]
   :ret :string}
  "One field's row inside the entity's Mermaid block: its SQL type,
  column name, and the PK/FK/UK marks its descriptor carries."
  [desc fname]
  (def f (get-in desc [:fields fname]))
  (def marks
    (string/join
      (filter |(not (empty? $))
              [(if (get f :db/pk) "PK" "")
               (if (get f :db/fk) "FK" "")
               (if (get f :db/unique) "UK" "")])
      ","))
  (string "    " (column-type f) " " (f :column)
          (if (empty? marks) "" (string " " marks))))

(defn- rel-lines
  {:params [{:name :keyword
             :rels {:keyword {:kind :keyword :entity :keyword
                              :through (or {:entity :keyword & r} :nil) & r}}
             & r}]
   :ret @[:string]}
  "One Mermaid relationship line per declared relation of this entity,
  cardinality read off its :kind (or :through, which is always
  many-to-many)."
  [desc]
  (seq [rname :in (sorted (keys (desc :rels)))]
    (def rel (get-in desc [:rels rname]))
    # left side is always this entity: belongs-to points many->one,
    # has-many one->many, has-one one->one — and a relation through a
    # middle is many-to-many however it is declared, because the row
    # in between is what makes it one
    (def cardinality
      (cond
        (rel :through) "}o--o{"
        (case (rel :kind)
          :belongs-to "}o--||"
          :has-many "||--o{"
          "||--o|")))
    (string "  " (desc :name) " " cardinality " " (rel :entity)
            " : " (string rname)
            (if-let [t (rel :through)]
              (string " (through " (string (t :entity)) ")")
              ""))))

(defn mermaid
  {:params [(or @[:keyword] [:keyword] :nil)] :ret :string}
  ``Render the registered entities (or a given subset of names) as a
  Mermaid erDiagram string.``
  [&opt names]
  (def which (or names (entity/registered)))
  (def out @["erDiagram"])
  (each n which
    (def desc (entity/resolve n))
    (array/push out (string "  " (desc :name) " {"))
    (each fname (desc :field-order)
      (array/push out (field-line desc fname)))
    (array/push out "  }"))
  (each n which
    (array/concat out (rel-lines (entity/resolve n))))
  (string (string/join out "\n") "\n"))
