# Minimal repro for janet 1.41.2 (ADR-0015; upstream doc-semantics
# neighbour: janet-lang/janet#1523): closing a listener while a task
# is parked in net/accept first delivers a nil "connection", and only
# the NEXT accept errors with "stream is closed". net/accept's
# docstring promises a stream; an accept loop that passes the result
# straight to a handler dies later with
# "bad slot #0, expected core/stream, got nil".
#
#     janet scripts/janet-repro/accept-spurious-nil.janet
#
# Expected: accept either returns a real stream or errors on close.
# Actual on 1.41.2: one "accept -> ok=true conn=nil" line first.

(def l (net/listen "127.0.0.1" "0"))
(def [_ port] (net/localname l))

(ev/go
  (fn accept-loop []
    (while true
      (def [ok conn] (protect (net/accept l)))
      (printf "accept -> ok=%q conn=%q" ok conn)
      (unless ok (break))
      (when (nil? conn) (print "!!! nil connection from net/accept")))))

(ev/sleep 0.05)

# one real connection is accepted normally
(def c (net/connect "127.0.0.1" (string port)))
(ev/sleep 0.05)
(:close c)

# closing the listener wakes the parked accept with nil, then errors
(:close l)
(ev/sleep 0.1)
(print "done")
