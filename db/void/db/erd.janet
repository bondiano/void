### void/db/erd — entity registry -> ER diagram (ROADMAP 2.1, wave-2
### exit criterion 3).
###
### `:db/rels` and `:db/fk` are the single source of truth for the
### preload planner, admin relation widgets and migrations-diff — the
### diagram is one more projection of the same declarations, never a
### hand-maintained picture that drifts. Output is Mermaid
### (erDiagram), which renders in GitHub, the docs site and the void
### admin without a toolchain.

(import ./entity :as entity)

(defn- field-line [desc fname]
  (def f (get-in desc [:fields fname]))
  (def marks
    (string/join
      (filter |(not (empty? $))
              [(if (get f :db/pk) "PK" "")
               (if (get f :db/fk) "FK" "")
               (if (get f :db/unique) "UK" "")])
      ","))
  (string "    " (or (get f :db/type) "value") " " (f :column)
          (if (empty? marks) "" (string " " marks))))

(defn- rel-lines [desc]
  (seq [rname :in (sorted (keys (desc :rels)))]
    (def rel (get-in desc [:rels rname]))
    # left side is always this entity: belongs-to points many->one,
    # has-many one->many, has-one one->one
    (def cardinality
      (case (rel :kind)
        :belongs-to "}o--||"
        :has-many "||--o{"
        "||--o|"))
    (string "  " (desc :name) " " cardinality " " (rel :entity)
            " : " (string rname))))

(defn mermaid
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
