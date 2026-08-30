### void/mcp/stdio — the transport that owns a process's stdin
### (SPEC.md §5.18, ADR-0031).
###
### MCP's stdio framing is a line: one JSON-RPC message per line, no
### embedded newlines, no length header (that is LSP, and the
### resemblance has cost more than one implementation an afternoon).
### So the loop is small — read, split, dispatch, write — and the
### interesting decisions are the three below.
###
### **stdout belongs to the protocol.** Everything else this process
### has to say goes to stderr, which is where both of the core's log
### sinks already write (ADR-0018) — and the one thing that would
### still land on stdout, a command's own `print`, is captured by
### ./registry into the tool's result. That capture is not a nicety:
### it is what makes an ordinary CLI command a well-behaved MCP tool
### without the command knowing what MCP is.
###
### **Messages are answered one at a time.** MCP allows a client to
### have several requests in flight, and a server may answer them out
### of order. This one does not: the tools are CLI commands, they were
### written to be run by a human at a shell, and two of them running
### concurrently in one process would share a `:out` binding, a
### database transaction context and whatever else the command keeps
### in a dyn. Sequential is the honest reading of what the tools are.
###
### **stdin is read through a stream, not through `file/read`.** A
### blocking read would freeze the ev loop, and this process is a
### whole application: a jobs worker, a scheduler and a bus consumer
### may all be running inside it while an agent is asking questions.

(import void/core/log :as log)
(import ./jsonrpc :as rpc)

(def log-ns "void.mcp.stdio")

(def default-max-message
  "Longest line accepted, in bytes. A frame is one message, so this is
  a bound on one message — a client that sends more than 4 MiB in one
  is not talking to a tool server."
  (* 4 1024 1024))

(defn open-stdin
  ``An ev-capable stream over this process's standard input. Janet
  hands out `stdin` as a blocking file; the fd is reachable as a
  stream through /dev/stdin (and /dev/fd/0 where that is what the
  platform calls it), and reading it through the loop is what lets the
  rest of the application keep running while the agent thinks.``
  []
  (var stream nil)
  (each path ["/dev/stdin" "/dev/fd/0"]
    (unless stream
      (def [ok s] (protect (os/open path :r)))
      (when (and ok s) (set stream s))))
  (or stream
      (error (string "cannot open standard input as a stream (tried /dev/stdin and "
                     "/dev/fd/0) — the stdio transport needs a readable stdin"))))

(defn write-message
  "Write one message as one line to `out` (a file, default stdout)."
  [msg &opt out]
  (default out stdout)
  (file/write out (rpc/encode msg) "\n")
  (file/flush out)
  msg)

(defn serve
  ``Read messages from stdin and answer them on stdout until the
  client closes the stream. `handler` is (fn [decoded-message] ->
  response-message | nil) — ./init passes one that dispatches against
  this process's projection.

  Options:
    :in           the input stream (default: this process's stdin)
    :write        (fn [message]) — default: one line on stdout
    :max-message  bytes, default 4 MiB

  Returns the number of messages handled, which is what the suite
  asserts on and what the log line at the end reports.``
  [handler &opt opts]
  (default opts {})
  (def in (or (get opts :in) (open-stdin)))
  (def write (or (get opts :write) write-message))
  (def limit (get opts :max-message default-max-message))
  (def acc @"")
  (var handled 0)
  (var running true)
  (while running
    (def chunk (ev/read in 65536))
    (if (nil? chunk)
      (set running false)                      # the client hung up
      (do
        (buffer/push acc chunk)
        (var nl (string/find "\n" acc))
        (while nl
          (def line (string/trim (string/slice acc 0 nl)))
          (buffer/blit acc (buffer/slice acc (inc nl)) 0)
          (buffer/popn acc (inc nl))
          (unless (empty? line)
            (++ handled)
            (def decoded (rpc/decode line))
            (if-let [err (get decoded :error)]
              (write err)
              (let [msg (decoded :ok)
                    [ok answer] (protect (handler msg))]
                (cond
                  ok (when answer (write answer))
                  # a handler that throws is this server's fault, not
                  # the client's: say so with the id, so the client
                  # stops waiting
                  (get msg :notification?)
                  (log/error "mcp handler failed on a notification" :ns log-ns
                             :method (get msg :method)
                             :err (if (string? answer) answer (describe answer)))
                  (write (rpc/fail (get msg :id) :internal-error
                                   (if (string? answer) answer (describe answer))))))))
          (set nl (string/find "\n" acc)))
        (when (> (length acc) limit)
          (buffer/clear acc)
          (write (rpc/fail nil :invalid-request
                           (string/format "message longer than %d bytes" limit)))))))
  (log/info "mcp stdio server done" :ns log-ns :messages handled)
  handled)
