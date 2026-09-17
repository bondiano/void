### void/core/cli — what a CLI command declares, read by one parser.
###
### The `:void.core/cli` point is void/core's, and until now the only
### part of a command it carried was `:fn`: every command wrote its own
### flag loop (seven of them, two byte-for-byte identical), its own
### "takes no arguments" check and its own usage sentence inside
### `:doc`. The three drifted the way copies do — `void db migrate
### --help` answered "unknown flag", and the binary's own help list was
### a second table that had already fallen behind the dispatch it
### described.
###
### So a command declares its surface as data — `:args` positional
### names, `:flags` named ones — and this module is the only thing that
### reads it: `parse` turns argv into `[opts positional]` against that
### declaration, `usage` and `help` render the same declaration for a
### reader. A command that declares `:flags` is handed the parsed
### options table ahead of its positionals; one that declares neither
### gets its arguments raw, as it always did.
###
### The seam is here rather than in void/cli because the point is
### void/core's: `void/mcp` exposes the same contributions as agent
### tools, and a binary is not the only reader of what a command takes.

(import ./util :as util)

# -- the declaration -----------------------------------------------------

(def value-types
  ``How a flag's value is read from its argv string. `:bool` is the one
  that takes no value at all — the flag's presence *is* the value —
  and every other entry is a reader that throws with the flag named
  when the word will not parse.``
  {:string |$
   :int |(let [n (scan-number $)]
           (unless (and n (= n (math/floor n)))
             (errorf "expected a whole number, got %q" $))
           (math/floor n))
   :number |(or (scan-number $) (errorf "expected a number, got %q" $))
   :keyword |(keyword $)
   :keywords |(tuple ;(map keyword (string/split "," $)))
   :bool :presence})

(defn command-words
  {:params [:keyword] :ret [:string]}
  "The argv words a command keyword answers to: :routes -> (\"routes\"),
  :openapi/export -> (\"openapi\" \"export\")."
  [name]
  (tuple ;(string/split "/" (string name))))

(defn command-line
  {:params [{:name :keyword & r}] :ret :string}
  "How a command is typed, without its arguments: `void jobs list`."
  [command]
  (string "void " (string/join (command-words (command :name)) " ")))

# -- positionals ---------------------------------------------------------
#
# An :args entry is the name a usage line prints, and its spelling is
# the whole declaration: `ID` is required, `[KEY]` is optional and a
# trailing `...` makes it the rest. Nothing else to learn, and the
# usage line is the source rather than a second rendering of it.

(defn- arg-spec
  {:params [:string] :ret {:optional? :boolean :rest? :boolean}}
  "The parsed shape of one :args entry: whether `[...]`-wrapped, and
  whether it ends in `...`."
  [name]
  (def optional? (and (string/has-prefix? "[" name) (string/has-suffix? "]" name)))
  (def bare (if optional? (string/slice name 1 -2) name))
  {:optional? optional? :rest? (string/has-suffix? "..." bare)})

(defn arity
  {:params [(or @[:string] [:string])] :ret [:number :number?]}
  ``The positional count an :args declaration allows, as [min max]; max
  is nil when the last entry is a rest (`FIELD...`). An :args of []
  means "this command takes no arguments", which is a declaration and
  not an absence — a command that declares no :args at all is left to
  check its own.``
  [args]
  (var min 0)
  (var max 0)
  (var rest? false)
  (each a args
    (def s (arg-spec a))
    (unless (s :optional?) (++ min))
    (when (s :rest?) (set rest? true))
    (++ max))
  [min (unless rest? max)])

# -- usage and help ------------------------------------------------------

(defn- placeholder
  {:params [{:key :keyword & r}] :ret :string}
  "The value word a flag's usage prints: the key, shouted. `--limit N`
  would be shorter and `--limit LIMIT` is the one a reader can map back
  to what the command calls it."
  [spec]
  (string/ascii-upper (string (spec :key))))

(defn- flag-word
  {:params [:string {:key :keyword :type :keyword? & r}] :ret :string}
  "One flag as it is typed: bare for `:bool`, with its placeholder
  otherwise."
  [f spec]
  (if (= :bool (get spec :type :string))
    f
    (string f " " (placeholder spec))))

(defn flag-usage
  {:params [{:flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil) & r}]
   :ret @[:string]}
  "Each declared flag as it is typed, sorted: `[--limit LIMIT]`."
  [command]
  (def flags (get command :flags {}))
  (seq [f :in (sorted (keys flags))]
    (string "[" (flag-word f (flags f)) "]")))

(defn usage
  {:params [{:name :keyword
             :args (or @[:string] :nil)
             :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
             & r}]
   :ret :string}
  ``The one line that says how a command is typed, built from what it
  declares: `void jobs list [--limit LIMIT] [--queue QUEUE]`. A command
  that declares neither :args nor :flags has no surface to describe and
  gets its bare invocation.``
  [command]
  (string/join [(command-line command)
                ;(flag-usage command)
                ;(get command :args [])]
               " "))

(defn help
  {:params [{:name :keyword
             :doc :string?
             :args (or @[:string] :nil)
             :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
             & r}]
   :ret [:string]}
  ``The lines `--help` prints for one command: the usage, the
  docstring, and a table of the flags with theirs. Data in, text out —
  there is no second place a command's surface is written down.``
  [command]
  (def out @[(string "usage: " (usage command))])
  (when-let [d (get command :doc)]
    (array/push out "")
    (array/push out d))
  (def flags (get command :flags {}))
  (unless (empty? flags)
    (array/push out "")
    (array/push out "Flags:")
    (each f (sorted (keys flags))
      (def spec (flags f))
      (array/push out (string/format "  %-24s %s"
                                     (flag-word f spec) (get spec :doc "")))))
  (tuple ;out))

(defn help-wanted?
  {:params [{:flags (or {:string :any} :nil) & r} (or @[:string] [:string])]
   :ret :boolean
   :narrows :any}
  "Is this invocation asking for the command's help rather than for the
  command? `--help` or `-h` anywhere in the arguments, unless the
  command declares `--help` as a flag of its own."
  [command args]
  (and (nil? (get-in command [:flags "--help"]))
       (truthy? (some |(or (= "--help" $) (= "-h" $)) args))))

(defn summary
  {:params [{:name :keyword :args (or @[:string] :nil) :doc :string? & r} (or :number :nil)]
   :ret :string}
  ``One command as a help listing prints it: how it is typed — the
  words and their positionals, the flags left to `--help` — padded to
  `width`, then its docstring. The listing and the per-command help
  read the same declaration, which is the whole point of there being
  one.``
  [command &opt width]
  (default width 22)
  (string/format (string "  %-" width "s %s")
                 (string/join [;(command-words (command :name))
                               ;(get command :args [])] " ")
                 (get command :doc "")))

# -- parsing -------------------------------------------------------------

(defn- flag-reader
  {:params [{:name :keyword & r} :string {:type :keyword? & r}]
   :ret (or (fn [:string] :any) :keyword)
   :throws [:string]}
  "The reader for one flag's declared :type — a function from its argv
  word to the parsed value, or `:presence` for `:bool`. Throws when the
  declared :type is not one `value-types` knows."
  [command flag spec]
  (def t (get spec :type :string))
  (or (in value-types t)
      (errorf "%s: flag %s declares unknown :type %q (one of: %s)"
              (command-line command) flag t (util/names-str (keys value-types)))))

(defn parse
  {:params [{:name :keyword
             :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
             :args (or @[:string] :nil)
             & r}
            (or @[:string] [:string])]
   :ret [@{:keyword :any} [:string]]
   :throws [:string]}
  ``Split `args` into [opts positional] against a command's
  declaration: every `:flags` entry recognized wherever it appears,
  everything else kept in order as a positional. An unknown flag — any
  unconsumed word starting with `--` — is an error naming the ones
  that exist; a flag that wants a value and is last is an error saying
  so; and a positional count `:args` does not allow is the usage line.

  Flags are recognized after positionals as well as before, because the
  alternative is explaining to a reader why `void jobs list --limit 5`
  works and `void storage put f.txt --expires 60` does not.``
  [command args]
  (def flags (get command :flags {}))
  (def opts @{})
  (def pos @[])
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (def spec (in flags a))
    (cond
      spec
      (let [read (flag-reader command a spec)]
        (if (= :presence read)
          (do (put opts (spec :key) true) (++ i))
          (do
            (unless (< (inc i) (length args))
              (errorf "%s: %s needs a value" (command-line command) a))
            (def [ok v] (protect (read (args (inc i)))))
            (unless ok
              (errorf "%s: %s %s" (command-line command) a (util/err-str v)))
            (put opts (spec :key) v)
            (+= i 2))))

      (and (string/has-prefix? "--" a) (not (empty? flags)))
      (errorf "%s: unknown flag %q (known: %s)%s"
              (command-line command) a
              (string/join (sorted (keys flags)) " ")
              (util/suggest a (keys flags)))

      (do (array/push pos a) (++ i))))

  (when-let [as (get command :args)]
    (def [min max] (arity as))
    (when (or (< (length pos) min) (and max (> (length pos) max)))
      (errorf "usage: %s" (usage command))))
  [opts (tuple ;pos)])

(defn call
  {:params [{:name :keyword
             :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
             :args (or @[:string] :nil)
             & r}
            (fn [& :any] :any)
            (or @[:any] [:any])
            (or @[:string] [:string])]
   :ret :any
   :throws [:string]}
  ``Run a command's `:fn` over `args`, with the instances its `:needs`
  resolved to already. This is the whole calling convention, in one
  place: the arguments are parsed against the declaration, a command
  that declares `:flags` is handed the options table ahead of its
  positionals, and a command that declares neither is handed its
  arguments untouched — which is what every command did before it had
  anything to declare.``
  [command f instances args]
  (if (and (nil? (get command :flags)) (nil? (get command :args)))
    (f ;instances ;args)
    (let [[opts pos] (parse command args)]
      (if (get command :flags)
        (f ;instances opts ;pos)
        (f ;instances ;pos)))))
