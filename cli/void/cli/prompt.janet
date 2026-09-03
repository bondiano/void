### void/cli/prompt — the questions a generator asks, and the two ways
### they can be answered — including interactively, through rawterm.
###
### A scaffolder that only works in front of a human is a scaffolder
### nobody can run from a Makefile, from CI or from `void make resource
### User < answers.txt`. So a question here has one definition and two
### front ends: on a terminal `spork/rawterm` puts stdin in raw mode and
### draws the prompt — a default you accept with Enter, a list you walk
### with the arrow keys — and everywhere else the very same question
### reads one line from stdin and falls back to its default at EOF.
### Nothing asks twice and nothing blocks a pipe.
###
### Raw mode is the only piece of global terminal state the CLI touches,
### so it is entered and left inside a `defer`: a generator that throws
### with the tty still in raw mode leaves the user's shell without an
### echo, and the user has no way to know that the framework did it.
###
### The prompts are drawn on **stderr**. `void make resource ... --dry-run`
### prints the files it would write on stdout, and a redirect of that
### stdout must not swallow the question that produced it.

(import spork/rawterm)

# -- what the terminal sends ---------------------------------------------

(def- key-etx 3)                # Ctrl-C
(def- key-eot 4)                # Ctrl-D
(def- key-bell 7)
(def- key-bs 8)
(def- key-lf 10)
(def- key-cr 13)
(def- key-esc 27)
(def- key-del 127)

(def interactive-dyn
  ``Dyn that overrides tty detection. `nil` asks the terminal, anything
  else is the answer — tests and `--no-input` set it to false, which is
  what makes every prompt in this file exercisable without a pty.``
  :void.cli/interactive)

(defn interactive?
  "Is a human answering? True when stdin is a terminal, unless the
  `interactive-dyn` dyn says otherwise."
  []
  (def forced (dyn interactive-dyn))
  (if (nil? forced) (truthy? (rawterm/isatty)) (truthy? forced)))

(defn- say [& xs]
  (each x xs (eprin x))
  (eflush))

(def input-dyn
  ``Dyn that replaces the source of non-interactive answers: a
  `(fn [] line-or-nil)`. It exists so that the prompts can be driven
  from a test — and from a caller with the answers already in hand —
  without a pipe on stdin.``
  :void.cli/input)

(defn- read-line-plain
  "One line of input without raw mode — the non-interactive answer to
  every question here. `nil` at EOF, which every caller reads as
  \"take the default\"."
  []
  (if-let [f (dyn input-dyn)]
    (when-let [l (f)] (string/trim (string l)))
    (when-let [l (file/read stdin :line)]
      (string/trim (string l)))))

# -- raw-mode key reading ------------------------------------------------

(defn- read-key
  ``One keystroke in raw mode, as a byte or one of :up :down :left
  :right :enter :backspace :cancel :eof. An escape sequence is read as
  a unit: a bare ESC is `:cancel`, because a user who presses it wants
  out and not a stray byte in the answer.``
  []
  (def buf (rawterm/getch))
  (if (or (nil? buf) (empty? buf))
    :eof
    (let [c (buf 0)]
      (cond
        (or (= c key-cr) (= c key-lf)) :enter
        (or (= c key-del) (= c key-bs)) :backspace
        (= c key-etx) :cancel
        (= c key-eot) :eof
        (= c key-esc)
        (let [b (rawterm/getch)]
          (if (or (nil? b) (empty? b) (not= (b 0) (chr "[")))
            :cancel
            (let [d (rawterm/getch)]
              (case (if (or (nil? d) (empty? d)) 0 (d 0))
                (chr "A") :up
                (chr "B") :down
                (chr "C") :right
                (chr "D") :left
                :cancel))))
        c))))

(defn- with-raw*
  "Run `f` with stdin in raw mode, restoring the terminal whatever
  happens — including a throw and including Ctrl-C."
  [f]
  (rawterm/begin)
  (defer (rawterm/end) (f)))

(defn cancelled
  "The error a prompt throws when the user asks to leave (Ctrl-C, ESC).
  A generator catches nothing: `void: cancelled` and exit 1 is the
  whole of the intended behaviour."
  []
  (error "cancelled"))

# -- ask -----------------------------------------------------------------

(defn- label [question default]
  (if (and default (not (empty? (string default))))
    (string/format "%s [%s]: " question default)
    (string/format "%s: " question)))

(defn- validated
  "Apply an optional :validate — (fn [answer] nil | \"why not\") — and
  return the answer or nil after reporting the reason."
  [answer opts]
  (def v (get opts :validate))
  (if (nil? v)
    answer
    (if-let [why (v answer)]
      (do (say "  " why "\n") nil)
      answer)))

(defn ask
  ``Ask for one line of text:

      (prompt/ask "Table" {:default "users"})
      (prompt/ask "Name" {:validate (fn [s] (unless (valid? s) "letters only"))})

  Options: `:default` (returned on an empty answer and at EOF) and
  `:validate`. Returns a string; throws "cancelled" on Ctrl-C or ESC.
  A rejected answer is asked again on a terminal and is an error
  without one — a pipe has nothing else to offer.``
  [question &opt opts]
  (default opts {})
  (def dflt (get opts :default))
  (unless (interactive?)
    (say (label question dflt))
    (def raw (read-line-plain))
    (def answer (if (or (nil? raw) (empty? raw)) (string (or dflt "")) raw))
    (say answer "\n")
    (break (or (validated answer opts)
               (errorf "%s: %q is not a valid answer" question answer))))
  (var out nil)
  (while (nil? out)
    (def buf @"")
    (say (label question dflt))
    (with-raw*
      (fn []
        (var reading true)
        (while reading
          (def k (read-key))
          (cond
            (= k :enter) (set reading false)
            (= k :eof) (set reading false)
            (= k :cancel) (do (rawterm/end) (cancelled))
            (= k :backspace)
            (unless (empty? buf)
              (buffer/popn buf 1)
              (say "\b \b"))
            (int? k)
            (if (< k 32)
              (say (string/from-bytes key-bell))
              (do (buffer/push-byte buf k) (say (string/from-bytes k))))
            nil))))
    (say "\n")
    (def answer (let [s (string/trim (string buf))]
                  (if (empty? s) (string (or dflt "")) s)))
    (set out (validated answer opts)))
  out)

# -- choose --------------------------------------------------------------

(defn- option-label [o] (if (dictionary? o) (get o :label (string (o :value))) (string o)))
(defn- option-value [o] (if (dictionary? o) (get o :value (o :label)) o))
(defn- option-doc [o] (if (dictionary? o) (get o :doc "") ""))

(defn- draw-options [options cursor]
  (each [i o] (pairs options)
    (def doc (option-doc o))
    (eprintf " %s %-12s %s"
             (if (= i cursor) ">" " ")
             (option-label o)
             doc))
  (eflush))

(defn- erase-options [n]
  (say (string/format "\e[%dA\e[0J" n)))

(defn choose
  ``Pick one of a list:

      (prompt/choose "Type" [{:label "string" :value :string :doc "short text"}
                             {:label "int" :value :int}])

  An option is a string or a `{:label :value :doc}` table. On a
  terminal the list is drawn once and redrawn in place as the arrow
  keys (or `j`/`k`, or the option's number) move the cursor; Enter
  takes it. Without one, the labels are printed and one line is read —
  a label or a 1-based number, `:default`'s label at EOF.``
  [question options &opt opts]
  (default opts {})
  (when (empty? options) (errorf "%s: nothing to choose from" question))
  (def dflt (get opts :default))
  (def start (or (when dflt
                   (find-index |(= dflt (option-value $)) options))
                 0))
  (unless (interactive?)
    (say question " (" (string/join (map option-label options) ", ") ") ["
         (option-label (options start)) "]: ")
    (def raw (read-line-plain))
    (def answer (if (or (nil? raw) (empty? raw)) nil (string/trim raw)))
    (say (or answer (option-label (options start))) "\n")
    # a label first and a 1-based number second, so that an option
    # labelled "2" is answered by typing it
    (def by-label (find-index |(= answer (option-label $)) options))
    (def n (when answer (scan-number answer)))
    (break
      (cond
        (nil? answer) (option-value (options start))
        by-label (option-value (options by-label))
        (and n (int? n) (>= n 1) (<= n (length options)))
        (option-value (options (dec n)))
        (errorf "%s: %q is not one of %s" question answer
                (string/join (map option-label options) ", ")))))
  (say question "  (arrows or 1-" (string (length options)) ", enter to take)\n")
  (var cursor start)
  (var chosen nil)
  (draw-options options cursor)
  (with-raw*
    (fn []
      (var reading true)
      (while reading
        (def k (read-key))
        (def moved
          (cond
            (or (= k :up) (= k (chr "k"))) (do (set cursor (mod (dec cursor) (length options))) true)
            (or (= k :down) (= k (chr "j"))) (do (set cursor (mod (inc cursor) (length options))) true)
            (= k :enter) (do (set chosen (option-value (options cursor)))
                             (set reading false) false)
            (= k :eof) (do (set chosen (option-value (options cursor)))
                           (set reading false) false)
            (= k :cancel) (do (rawterm/end) (cancelled))
            (and (int? k) (>= k (chr "1")) (<= k (chr "9"))
                 (<= (- k (chr "0")) (length options)))
            (do (set cursor (dec (- k (chr "0")))) true)
            false))
        (when moved
          (erase-options (length options))
          (draw-options options cursor)))))
  (erase-options (length options))
  (say " " (option-label (options cursor)) "\n")
  chosen)

# -- confirm -------------------------------------------------------------

(defn confirm
  ``A yes/no question. `default` (true by default) is what Enter and
  EOF mean, and it is the one shown in capitals.``
  [question &opt dflt]
  (default dflt true)
  (def answer
    (ask (string question " " (if dflt "(Y/n)" "(y/N)"))
         {:default (if dflt "y" "n")
          :validate (fn [s]
                      (unless (index-of (string/ascii-lower s) ["y" "yes" "n" "no"])
                        "answer y or n"))}))
  (truthy? (index-of (string/ascii-lower answer) ["y" "yes"])))
