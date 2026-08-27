# Raw pipes for the test suite. `os/pipe` hands back janet streams,
# and a janet stream is precisely what fdwait is NOT for — the point
# of the shim is a descriptor the runtime knows nothing about, so the
# tests make one the same way a C library would.
(ffi/context nil)

# (ffi/defbind-alias <C symbol> <janet name> ...) — that order, whatever
# the docstring in boot.janet says.
(ffi/defbind-alias pipe c-pipe :int [fds :ptr])
(ffi/defbind-alias write c-write :long [fd :int buf :ptr n :size])
(ffi/defbind-alias read c-read :long [fd :int buf :ptr n :size])
(ffi/defbind-alias close c-close :int [fd :int])

(defn make
  "A fresh pipe as [read-fd write-fd]."
  []
  (def cell (ffi/malloc 8))
  (defer (ffi/free cell)
    (unless (zero? (c-pipe cell))
      (error "pipe() failed"))
    [(ffi/read :int cell 0) (ffi/read :int cell 4)]))

(defn put!
  "Write one byte into a pipe's write end."
  [fd]
  (c-write fd @"x" 1))

(defn take!
  "Read one byte from a pipe's read end; the string read."
  [fd]
  (def buf (buffer/new-filled 1))
  # ssize_t comes back as an s64 abstract, and buffer/slice wants a
  # plain integer
  (def n (int/to-number (c-read fd buf 1)))
  (string (buffer/slice buf 0 (max 0 n))))

(defn close! [fd] (c-close fd))
