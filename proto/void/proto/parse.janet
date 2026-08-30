### void/proto/parse — `.proto` source, as a PEG (SPEC.md §5.7,
### ADR-0013).
###
### One grammar, one tree, one pass that turns the tree into
### descriptors. The grammar is proto3's, and where the language has
### two dialects this one takes a side out loud: `syntax = "proto2"`,
### a `required` field, a `default =` option and a group are refused
### with a sentence saying so, because a parser that quietly accepted
### them would produce a message that encodes differently from what
### the file says.
###
### **Names are resolved here, references are not.** A field of type
### `Item` inside `message Order` in `package example` becomes
### `:example/Item` at parse time — the scope it was written in is
### gone by the time ./codec sees the descriptor, so it has to be. The
### *descriptor* it names is looked up later (./descriptor `resolve`),
### which is what lets a file mention a type before defining one and a
### message hold itself.
###
### **An import resolves against the registry first.** A file that
### imports `google/protobuf/timestamp.proto` needs no such file:
### ./wkt has registered the descriptor already. Anything else is read
### off disk, relative to the importing file and then to the paths the
### caller passed — and a missing one is an error naming both, rather
### than an unknown type twenty lines later.
###
### What the grammar knows and then throws away: comments, the order
### of options and every option void/proto has no use for. `option
### java_package = "..."` parses (a real file has one) and is kept as
### data on the file value, so a later projection can read it without
### the parser having to change.

(import ./descriptor :as desc)
(import ./wkt :as wkt)

# -- the grammar ---------------------------------------------------------

(defn- unescape
  "The body of a `.proto` string literal, with its escapes resolved."
  [s]
  (def out @"")
  (var i 0)
  (def n (length s))
  (while (< i n)
    (def c (in s i))
    (if (and (= c 92) (< (inc i) n))          # a backslash
      (let [e (in s (inc i))]
        (case (string/from-bytes e)
          "n" (do (buffer/push-byte out 10) (+= i 2))
          "r" (do (buffer/push-byte out 13) (+= i 2))
          "t" (do (buffer/push-byte out 9) (+= i 2))
          "0" (do (buffer/push-byte out 0) (+= i 2))
          "\\" (do (buffer/push-byte out 92) (+= i 2))
          "\"" (do (buffer/push-byte out 34) (+= i 2))
          "'" (do (buffer/push-byte out 39) (+= i 2))
          "x" (let [hex (string/slice s (+ i 2) (min n (+ i 4)))]
                (buffer/push-byte out (or (scan-number (string "0x" hex)) 0))
                (+= i 4))
          (do (buffer/push-byte out e) (+= i 2))))
      (do (buffer/push-byte out c) (++ i))))
  (string out))

(defn- kw [word]
  ~(* ,word (not :name-char) :ws))

(defn- p [punct]
  ~(* ,punct :ws))

(def grammar
  ``The proto3 grammar. Every token rule eats the whitespace and
  comments after itself, so the statement rules read like the
  language's own specification does.``
  ~{:comment (+ (* "//" (any (if-not (+ "\n" -1) 1)))
                (* "/*" (thru "*/")))
    :ws (any (+ (set " \t\r\n") :comment))
    :name-char (+ (range "az" "AZ" "09") "_")
    :ident-raw (* (+ (range "az" "AZ") "_") (any :name-char))
    :ident (* (<- :ident-raw) :ws)
    :dotted (* (<- (* (? ".") :ident-raw (any (* "." :ident-raw)))) :ws)
    :number (* (/ (<- (* (? (set "-+"))
                         (+ (* "0" (set "xX") (some (range "09" "af" "AF")))
                            (* (some (range "09")) (? (* "." (some (range "09"))))
                               (? (* (set "eE") (? (set "-+")) (some (range "09")))))
                            (* "." (some (range "09"))))))
                  ,scan-number)
               :ws)
    :int (* (/ (<- (* (? (set "-+")) (some (range "09")))) ,scan-number) :ws)
    :string-lit (* (/ (+ (* `"` (<- (any (+ (* "\\" 1) (if-not `"` 1)))) `"`)
                         (* "'" (<- (any (+ (* "\\" 1) (if-not "'" 1)))) "'"))
                      ,unescape)
                   :ws)
    :bool-lit (+ (* (/ (<- "true") ,(fn [_] true)) (not :name-char) :ws)
                 (* (/ (<- "false") ,(fn [_] false)) (not :name-char) :ws))
    # an aggregate option value: kept as its source text, because the
    # only thing void/proto does with a custom option is carry it
    :aggregate (* (<- (* "{" (any (+ (if-not (set "{}") 1) :aggregate-inner)) "}")) :ws)
    :aggregate-inner (* "{" (any (+ (if-not (set "{}") 1) :aggregate-inner)) "}")
    :constant (+ :bool-lit :string-lit :number :aggregate :dotted)
    :option-name (* (<- (+ (* "(" :dotted-raw ")" (any (* "." :ident-raw)))
                           (* :ident-raw (any (* "." :ident-raw)))))
                    :ws)
    :dotted-raw (* (? ".") :ident-raw (any (* "." :ident-raw)))

    :empty ,(p ";")
    :option-stmt (group (* (constant :option) ,(kw "option")
                           :option-name ,(p "=") :constant ,(p ";")))
    :field-opt (group (* :option-name ,(p "=") :constant (? ,(p ","))))
    :field-opts (+ (* ,(p "[") (group (* :field-opt (any :field-opt))) ,(p "]"))
                   (constant []))

    :label (+ (* (<- "repeated") (not :name-char) :ws)
              (* (<- "optional") (not :name-char) :ws)
              (* (<- "required") (not :name-char) :ws)
              (constant "singular"))
    :field (group (* (constant :field) :label :dotted :ident
                     ,(p "=") :int :field-opts ,(p ";")))
    :map-field (group (* (constant :map-field) ,(kw "map") ,(p "<")
                         :dotted ,(p ",") :dotted ,(p ">")
                         :ident ,(p "=") :int :field-opts ,(p ";")))
    :oneof-field (group (* (constant :field) (constant "singular") :dotted :ident
                           ,(p "=") :int :field-opts ,(p ";")))
    :oneof (group (* (constant :oneof) ,(kw "oneof") :ident ,(p "{")
                     (group (any (+ :option-stmt :oneof-field :empty)))
                     ,(p "}")))
    :range (group (+ (* :int ,(kw "to") (+ (* (<- "max") :ws) :int)) :int))
    :reserved (group (* (constant :reserved) ,(kw "reserved")
                        (group (+ (* :string-lit (any (* ,(p ",") :string-lit)))
                                  (* :range (any (* ,(p ",") :range)))))
                        ,(p ";")))
    :extensions (group (* (constant :extensions) ,(kw "extensions")
                          (group (* :range (any (* ,(p ",") :range)))) ,(p ";")))
    :group-decl (group (* (constant :group) :label ,(kw "group") :ident
                          ,(p "=") :int ,(p "{") (any (if-not "}" 1)) ,(p "}")))
    :message-member (+ :option-stmt :map-field :oneof :reserved :extensions
                       :message :enum :group-decl :field :empty)
    :message (group (* (constant :message) ,(kw "message") :ident ,(p "{")
                       (group (any :message-member)) ,(p "}")))

    :enum-value (group (* (constant :value) :ident ,(p "=") :int :field-opts ,(p ";")))
    :enum (group (* (constant :enum) ,(kw "enum") :ident ,(p "{")
                    (group (any (+ :option-stmt :reserved :enum-value :empty)))
                    ,(p "}")))

    :stream (+ (* (/ (<- "stream") ,(fn [_] true)) (not :name-char) :ws)
               (constant false))
    :rpc (group (* (constant :rpc) ,(kw "rpc") :ident
                   ,(p "(") :stream :dotted ,(p ")")
                   ,(kw "returns")
                   ,(p "(") :stream :dotted ,(p ")")
                   (+ (* ,(p "{") (group (any (+ :option-stmt :empty))) ,(p "}"))
                      (* (constant []) ,(p ";")))))
    :service (group (* (constant :service) ,(kw "service") :ident ,(p "{")
                       (group (any (+ :rpc :option-stmt :empty)))
                       ,(p "}")))

    :syntax (group (* (constant :syntax) ,(kw "syntax") ,(p "=") :string-lit ,(p ";")))
    :package (group (* (constant :package) ,(kw "package") :dotted ,(p ";")))
    :import (group (* (constant :import) ,(kw "import")
                      (+ (* (<- (+ "public" "weak")) (not :name-char) :ws)
                         (constant ""))
                      :string-lit ,(p ";")))
    :statement (+ :import :package :option-stmt :message :enum :service :empty)
    :main (* :ws (? :syntax) (group (any :statement)) -1)})

(def- compiled (peg/compile grammar))

(defn tokens
  ``Parse `.proto` source into the statement tree — the grammar's own
  output, before any of it means anything. Public because it is what a
  test asserts on when it is the *parser* under test rather than the
  descriptors.``
  [source &opt where]
  (def caps (peg/match compiled source))
  (unless caps
    (errorf "proto: %s is not a .proto file this parser understands"
            (or where "the source")))
  (if (= 1 (length caps))
    {:syntax nil :statements (first caps)}
    {:syntax (last (first caps)) :statements (caps 1)}))

# -- the tree becomes descriptors ----------------------------------------

(defn- qualify [prefix name]
  (if (empty? prefix) name (string prefix "." name)))

(defn- collect-names
  "Every message and enum a statement tree defines, fully qualified."
  [statements prefix into]
  (each st statements
    (case (first st)
      :message (let [full (qualify prefix (st 1))]
                 (put into full :message)
                 (collect-names (st 2) full into))
      :enum (put into (qualify prefix (st 1)) :enum)
      nil))
  into)

(defn- resolve-type
  ``The fully-qualified name of a type as written inside `scope`.
  protobuf's own rule: a leading dot is absolute, and everything else
  is looked for from the innermost scope outward — so `Item` inside
  `example.Order` finds `example.Order.Item` before `example.Item`.``
  [written scope known where]
  (def name (string written))
  (if (string/has-prefix? "." name)
    (string/slice name 1)
    (do
      (def parts (if (empty? scope) [] (string/split "." scope)))
      (var found nil)
      (loop [i :down-to [(length parts) 0] :when (nil? found)]
        (def candidate (qualify (string/join (slice parts 0 i) ".") name))
        (when (or (known candidate) (desc/lookup (desc/name-of candidate)))
          (set found candidate)))
      (or found
          (errorf (string "proto: %s: no type named %q is in scope at %q. "
                          "The file defines %s; anything else has to be imported.")
                  where name (if (empty? scope) "the top level" scope)
                  (let [ns (sorted (keys known))]
                    (if (empty? ns) "nothing" (string/join ns " "))))))))

(defn- field-options [opts]
  (def out @{})
  (each o opts
    (def [k v] o)
    (case (string k)
      "json_name" (put out :json-name (string v))
      "packed" (put out :packed (truthy? v))
      "deprecated" (put out :deprecated (truthy? v))
      "default" (error (string "proto: `default = ` is a proto2 option — in proto3 an unset "
                               "field decodes to its type's zero, and there is no second answer"))
      nil))
  out)

(defn- type-form [written scope known where]
  (if (desc/scalars (keyword written))
    (keyword written)
    (desc/name-of (resolve-type written scope known where))))

(defn- field-entry [st scope known where]
  (def [_ label type name number opts] st)
  (when (= "required" label)
    (errorf (string "proto: %s: field %q is `required`, which proto3 removed — a reader "
                    "cannot enforce it and a writer cannot rely on it")
            where name))
  (def o (field-options opts))
  [(keyword name)
   [number
    ;(case label "repeated" [:repeated] "optional" [:optional] [])
    (type-form type scope known where)
    o]])

(defn- map-entry [st scope known where]
  (def [_ ktype vtype name number opts] st)
  [(keyword name)
   [number :map
    (type-form ktype scope known where)
    (type-form vtype scope known where)
    (field-options opts)]])

(defn- build-enum [st prefix where]
  (def [_ name members] st)
  (def full (qualify prefix name))
  (def values @{})
  (var allow-alias false)
  (each m members
    (case (first m)
      :value (put values (keyword (m 1)) (m 2))
      :option (when (and (= "allow_alias" (string (m 1))) (truthy? (m 2)))
                (set allow-alias true))
      nil))
  (desc/enum (desc/name-of full) values {:proto-name full :allow-alias allow-alias}))

(varfn build-message [st prefix known where out] nil)

(varfn build-message [st prefix known where out]
  (def [_ name members] st)
  (def full (qualify prefix name))
  (def fields @{})
  (def reserved @[])
  (each m members
    (case (first m)
      :field (let [[k v] (field-entry m full known where)] (put fields k v))
      :map-field (let [[k v] (map-entry m full known where)] (put fields k v))
      :oneof (let [oname (keyword (m 1))]
               (each f (m 2)
                 (when (= :field (first f))
                   (def [k v] (field-entry f full known where))
                   (def opts (merge (last v) {:oneof oname}))
                   (put fields k [;(slice v 0 -2) opts]))))
      :group (errorf (string "proto: %s: `group` is a proto2 construct that proto3 removed "
                             "(and that void/proto never writes) — use a nested message")
                     where)
      :extensions (errorf (string "proto: %s: `extensions` is proto2 — proto3 has no extension "
                                  "ranges, and an unknown field survives a round trip here "
                                  "without one")
                          where)
      :reserved (array/push reserved (m 1))
      :message (build-message m full known where out)
      :enum (array/push out (build-enum m full where))
      nil))
  (array/push out (desc/message (desc/name-of full) fields
                                {:proto-name full :reserved (tuple ;reserved)}))
  out)

(defn- build-service [st prefix known where]
  (def [_ name members] st)
  (def full (qualify prefix name))
  (def methods @[])
  (each m members
    (when (= :rpc (first m))
      (def [_ mname client-streaming input server-streaming output opts] m)
      (var idempotent false)
      (each o opts
        (when (and (= :option (first o))
                   (= "idempotency_level" (string (o 1)))
                   (= "NO_SIDE_EFFECTS" (string (o 2))))
          (set idempotent true)))
      (array/push methods
                  {:name (keyword mname)
                   :proto-name mname
                   :input (desc/name-of (resolve-type input full known where))
                   :output (desc/name-of (resolve-type output full known where))
                   :client-streaming client-streaming
                   :server-streaming server-streaming
                   :idempotent idempotent})))
  (desc/service (desc/name-of full) methods {:proto-name full}))

# -- files ---------------------------------------------------------------

(defn- file-options [statements]
  (def out @{})
  (each st statements
    (when (= :option (first st))
      (put out (keyword (st 1)) (st 2))))
  out)

(defn parse
  ``Parse `.proto` source into a file value:

      {:syntax "proto3" :package "example" :imports [...]
       :options {...} :descriptors [<message|enum|service> ...]}

  Nothing is registered — `register-file!` does that, and keeping the
  two apart is what lets a caller parse a file to look at it. `where`
  names the source in error messages.``
  [source &opt where known-outside]
  (default where "<string>")
  (def tree (tokens source where))
  (def syntax (or (tree :syntax) "proto2"))
  (unless (= "proto3" syntax)
    (errorf (string "proto: %s declares syntax %q. void/proto speaks proto3 — proto2's "
                    "required fields, groups and field defaults have no encoding here, and "
                    "guessing at one would produce a message that is not what the file says")
            where syntax))
  (def statements (tree :statements))
  (def package (or (first (seq [st :in statements :when (= :package (first st))] (st 1))) ""))
  (def imports (seq [st :in statements :when (= :import (first st))] (st 2)))
  (def known (collect-names statements package (merge @{} (or known-outside {}))))
  (def out @[])
  (each st statements
    (case (first st)
      :message (build-message st package known where out)
      :enum (array/push out (build-enum st package where))
      :service (array/push out (build-service st package known where))
      nil))
  {:syntax syntax
   :package package
   :imports (tuple ;imports)
   :options (file-options statements)
   :descriptors (tuple ;out)
   :source where})

(defn register-file!
  ``Register every descriptor a parsed file defines, then flush — so
  the watchers see a whole file at once and a message that names a
  type defined below it still projects (see `descriptor/watch!`).
  Returns the file.``
  [file]
  (each d (file :descriptors) (desc/register! d))
  (desc/flush!)
  file)

# -- reading from disk ---------------------------------------------------

(defn- dirname [path]
  (def idxs (string/find-all "/" path))
  (if (empty? idxs) "." (string/slice path 0 (last idxs))))

(defn- readable [path]
  (when (= :file (os/stat path :mode)) path))

(defn find-file
  ``Where an `import "a/b.proto"` points: next to the importing file
  first, then along `paths`. nil when it is nowhere — the caller says
  what that means, because for a `google/protobuf/*.proto` it means
  ./wkt has it already.``
  [target &opt from paths]
  (some readable
        [;(if from [(string (dirname from) "/" target)] [])
         ;(map |(string $ "/" target) (or paths []))
         target]))

(defn load
  ``Read a `.proto` file and everything it imports, parse all of it and
  register the descriptors. Returns the file value of `path`.

  Imports are followed depth-first and each file is parsed once —
  `imports` is the set already seen, which is also what makes a cycle
  (legal in protobuf, common in practice) terminate. A path that is
  neither on disk nor a well-known type is an error naming where it
  looked.``
  [path &opt opts]
  (default opts {})
  (def seen (or (opts :seen) @{}))
  (def paths (get opts :paths []))
  (def full (or (find-file path (opts :from) paths)
                (if (string/has-prefix? "google/protobuf/" path)
                  (errorf (string "proto: %q is a well-known type void/proto does not carry "
                                  "(it has %s). Put the file on the import path to parse it "
                                  "as an ordinary message — but see ./wkt for what its JSON "
                                  "form would still be missing")
                          path (string/join (sorted (keys wkt/files)) " "))
                  (errorf "proto: no such file %q (looked next to %q and in %s)"
                          path (or (opts :from) ".")
                          (if (empty? paths) "no other path" (string/join paths " "))))))
  (def real (os/realpath full))
  (when (seen real) (break (seen real)))
  (put seen real :loading)
  (def source (slurp real))
  # imports first, so their names are registered before this file's
  # types are resolved against them
  (def tree (tokens source real))
  (each st (tree :statements)
    (when (= :import (first st))
      (def target (st 2))
      (unless (wkt/file target)
        (load target (merge opts {:from real :seen seen})))))
  (def file (register-file! (parse source real)))
  (put seen real file)
  file)
