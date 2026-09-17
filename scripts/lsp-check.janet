### Ask janet-zed what it makes of a file, the way the editor asks.
###
### The types void writes down are only worth what a reader makes of
### them, so they are checked by the reader itself: `janet-zed-server`
### over LSP, with `types.diagnostics` turned up to `warning` so that
### everything inference rules out is reported rather than hinted.
###
###     janet scripts/lsp-check.janet core/void/core/semver.janet
###     janet scripts/lsp-check.janet http/            # every file under it
###
### A diagnostic is half of it. An annotation janet-zed cannot read —
### a type that does not parse, `:params` that do not fit the parameter
### list — is dropped whole and silently, and a dropped annotation
### rules nothing out, so it would pass as clean. Each file is
### therefore asked a second time, with `:ret :never` written last
### into every signature in memory: the last key wins, so a hover
### that does not answer `-> :never` names an annotation nobody read.
###
### A named type is a third way to read nothing: `HttpRequest` spelled
### `HttpReqest` is a variable nobody binds, and a variable rules nothing
### out either. Every capitalised name a signature uses must therefore be
### declared with `:typedef` — in the file itself or in a `*.d.janet`
### anywhere under the repository.
###
### Prints one line per finding and exits non-zero when there is any.

(import spork/json)

(def- root (os/cwd))

(defn- files
  {:params [[:string]] :ret @[:string]}
  "Every `.janet` file under the paths given, a file standing for itself."
  [args]
  (def out @[])
  (defn walk [path]
    (case (os/stat path :mode)
      :directory (each entry (sort (os/dir path))
                   (unless (string/has-prefix? "." entry) (walk (string path "/" entry))))
      :file (when (string/has-suffix? ".janet" path) (array/push out path))))
  (each arg args (walk arg))
  out)

(defn- uri
  {:params [:string] :ret :string}
  "The `file://` URI of a path relative to the repository root."
  [path]
  (string "file://" (if (string/has-prefix? "/" path) path (string root "/" path))))

(defn- send
  {:params [:abstract {:keyword :any}] :ret :nil}
  "Frame one JSON-RPC message onto the server's stdin."
  [stream message]
  (def body (json/encode (merge {:jsonrpc "2.0"} message)))
  (ev/write stream (string "Content-Length: " (length body) "\r\n\r\n" body))
  nil)

(defn- receive
  {:params [:abstract :buffer] :ret {:keyword :any} :throws [:string]}
  "One message off the stream: headers, then exactly the bytes they announce."
  [stream buf]
  (defn fill []
    (unless (ev/read stream 4096 buf) (error "janet-zed-server closed the connection")))
  (var head (string/find "\r\n\r\n" buf))
  (while (not head) (fill) (set head (string/find "\r\n\r\n" buf)))
  (def size (scan-number (string/trim (last (string/split ":" (string/slice buf 0 head))))))
  (def start (+ head 4))
  (while (< (length buf) (+ start size)) (fill))
  (def body (string/slice buf start (+ start size)))
  (def rest (string/slice buf (+ start size)))
  (buffer/clear buf)
  (buffer/push-string buf rest)
  (json/decode body true true))

(defn- request
  {:params [:abstract :abstract :buffer :number :string :any] :ret {:keyword :any}}
  "Send a request and answer its reply, passing over the notifications in between."
  [in out buf id method params]
  (send in {:id id :method method :params params})
  (var reply nil)
  (while (nil? reply)
    (def message (receive out buf))
    (when (= id (get message :id)) (set reply message)))
  reply)

(def- definition-head
  (peg/compile
    ~{:ws (set " \t\r\n")
      :name (<- (some (if-not (+ :ws (set "()[]{}")) 1)))
      :main (* "(" (+ "defmacro-" "defmacro" "defn-" "defn") (some :ws)
               (position) :name (any :ws) (position) "{")}))

(defn- struct-end
  {:params [:string :number] :ret :number?}
  "The offset of the `}` closing the struct that opens at `start`, past strings and comments."
  [text start]
  (var depth 0)
  (var i start)
  (var end nil)
  (while (and (nil? end) (< i (length text)))
    (def c (text i))
    (cond
      (= c (chr `"`)) (do (++ i)
                        (while (and (< i (length text)) (not= (text i) (chr `"`)))
                          (when (= (text i) (chr `\`)) (++ i))
                          (++ i)))
      (= c (chr "#")) (while (and (< i (length text)) (not= (text i) (chr "\n"))) (++ i))
      (has-value? "([{" c) (++ depth)
      (has-value? ")]}" c) (do (-- depth) (when (zero? depth) (set end i))))
    (++ i))
  end)

(defn- signatures
  {:params [:string] :ret @[[:string :number :number :number :string]]}
  "Each top-level `defn` or `defmacro` whose metadata declares a signature: its name, the
  name's 0-based row and column, the offset of the metadata's closing brace, and the
  metadata's text."
  [text]
  (def out @[])
  (var row 0)
  (var start 0)
  (each line (string/split "\n" text)
    (when-let [[at name open] (peg/match definition-head text start)
               close (struct-end text open)]
      (def meta (string/slice text open close))
      (when (some |(string/find $ meta) [":params" ":ret" ":throws"])
        (array/push out [name row (- at start) close meta])))
    (+= start (inc (length line)))
    (++ row))
  out)

(defn- probe
  {:params [:string [[:string :number :number :number :string]]] :ret :string}
  "The text with `:ret :never` written last into every signature, back to front so that each
  offset still points where it did."
  [text sigs]
  (reduce (fn [out [_ _ _ close]]
            (string (string/slice out 0 close) " :ret :never" (string/slice out close)))
          text (reverse sigs)))

(def- typedef-head
  (peg/compile
    ~(any (+ (* "(def" (some :s) (<- (* (range "AZ") (any (if-not (set " \t\r\n()[]{}") 1))))
                (some :s) ":typedef")
             1))))

(def- tokens
  (peg/compile ~(any (+ (<- (some (if-not (set " \t\r\n()[]{}") 1))) 1))))

(defn- typedefs
  {:params [:string] :ret @{:string :boolean}}
  "Every name declared with `:typedef` in a `*.d.janet` under `dir`, plus the named types the
  core declarations carry."
  [dir]
  (def names @{"Pattern" true "CType" true})
  (defn walk [path]
    (case (os/stat path :mode)
      :directory (each entry (os/dir path)
                   (unless (or (string/has-prefix? "." entry) (index-of entry ["jpm_tree" "tmp"]))
                     (walk (string path "/" entry))))
      :file (when (string/has-suffix? ".d.janet" path)
              (each name (peg/match typedef-head (slurp path)) (put names name true)))))
  (walk dir)
  names)

(defn- unknown-types
  {:params [:string @{:string :boolean} @{:string :boolean}] :ret @[:string]}
  "The capitalised names in a signature's metadata that no `:typedef` declares, here or in
  the repository's declarations."
  [meta declared local]
  (distinct
    (seq [token :in (peg/match tokens meta)
          :let [name (if (string/has-suffix? "?" token) (string/slice token 0 -2) token)]
          :when (and (<= (chr "A") (first name) (chr "Z"))
                     (not (declared name))
                     (not (local name)))]
      name)))

(defn main
  {:params [:string] :ret :never}
  "Check every file named, print what janet-zed finds, and exit with whether it found anything."
  [& args]
  (def targets (files (drop 1 args)))
  (when (empty? targets)
    (eprint "usage: janet scripts/lsp-check.janet <file-or-directory>...")
    (os/exit 2))
  (def devnull (os/open "/dev/null" :w))
  (def server (os/spawn ["janet-zed-server"] :px {:in :pipe :out :pipe :err devnull}))
  (def [in out] [(server :in) (server :out)])
  (def buf @"")
  (var id 1)
  (request in out buf id "initialize"
           {:processId (os/getpid)
            :rootUri (uri ".")
            :capabilities {}
            :initializationOptions {:types {:diagnostics "warning"}}})
  (send in {:method "initialized" :params {}})
  (var found 0)
  (def declared (typedefs "."))
  (each target targets
    (def target-uri (uri target))
    (def text (slurp target))
    (send in {:method "textDocument/didOpen"
              :params {:textDocument {:uri target-uri :languageId "janet" :version 1
                                      :text text}}})
    (var waiting true)
    (while waiting
      (def message (receive out buf))
      (when (and (= "textDocument/publishDiagnostics" (get message :method))
                 (= target-uri (get-in message [:params :uri])))
        (set waiting false)
        (each diagnostic (get-in message [:params :diagnostics])
          (++ found)
          (def start (get-in diagnostic [:range :start]))
          (printf "%s:%d:%d %s" target (inc (start :line)) (inc (start :character))
                  (diagnostic :message)))))
    (def sigs (signatures (string text)))
    (def local (tabseq [name :in (peg/match typedef-head text)] name true))
    (each [name row col _ meta] sigs
      (each unknown (unknown-types meta declared local)
        (++ found)
        (printf "%s:%d:%d the annotation of %s names %s, which no :typedef declares"
                target (inc row) (inc col) name unknown)))
    (unless (empty? sigs)
      (send in {:method "textDocument/didChange"
                :params {:textDocument {:uri target-uri :version 2}
                         :contentChanges [{:text (probe (string text) sigs)}]}})
      (each [name row col] sigs
        (++ id)
        (def hover (request in out buf id "textDocument/hover"
                            {:textDocument {:uri target-uri}
                             :position {:line row :character col}}))
        (unless (string/find "-> :never" (or (get-in hover [:result :contents :value]) ""))
          (++ found)
          (printf "%s:%d:%d the annotation of %s is not read: a type that does not parse, or :params that do not fit the parameters"
                  target (inc row) (inc col) name))))
    (send in {:method "textDocument/didClose" :params {:textDocument {:uri target-uri}}}))
  (++ id)
  (request in out buf id "shutdown" nil)
  (send in {:method "exit" :params nil})
  (os/proc-wait server)
  (printf "# %d file(s), %d finding(s)" (length targets) found)
  (os/exit (if (zero? found) 0 1)))
