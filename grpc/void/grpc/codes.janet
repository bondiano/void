### void/grpc/codes — the sixteen answers an RPC can fail with.
###
### gRPC named them, Connect spells them in `snake_case` and carries
### them as an HTTP status plus a JSON body. All three spellings are
### one table here, because a code that means one thing to the server
### and another to the client is worse than no code at all.
###
### **Two directions, and they are not inverses.** `http-status` is
### the status a Connect error goes out with — the protocol fixes it,
### and it is not a matter of taste. `code-for-status` is the other
### way, and it exists because the rest of void raises HTTP: void/authz
### aborts 403, void/pressure sheds with 503, a body past the limit is
### 413. On an RPC route those have to reach the client as Connect
### errors rather than as an HTML page, and this is the table that says
### which. It is a judgement, so it is written down rather than
### inferred.

(import void/core/errors :as errors)

(def codes
  ``Every Connect/gRPC code: its number, and the HTTP status the
  Connect protocol sends it with.``
  {:canceled {:number 1 :status 499}
   :unknown {:number 2 :status 500}
   :invalid_argument {:number 3 :status 400}
   :deadline_exceeded {:number 4 :status 504}
   :not_found {:number 5 :status 404}
   :already_exists {:number 6 :status 409}
   :permission_denied {:number 7 :status 403}
   :resource_exhausted {:number 8 :status 429}
   :failed_precondition {:number 9 :status 400}
   :aborted {:number 10 :status 409}
   :out_of_range {:number 11 :status 400}
   :unimplemented {:number 12 :status 501}
   :internal {:number 13 :status 500}
   :unavailable {:number 14 :status 503}
   :data_loss {:number 15 :status 500}
   :unauthenticated {:number 16 :status 401}})

(def names
  "The codes, sorted — what an error message lists when it refuses one."
  (sorted (keys codes)))

(defn code?
  "Is this one of the sixteen?"
  [code]
  (truthy? (codes code)))

(defn http-status
  "The HTTP status the Connect protocol carries this code with."
  [code]
  (get-in codes [code :status]
          (get-in codes [:unknown :status])))

(defn number
  "The gRPC number of a code — what a `grpc-status` trailer would say."
  [code]
  (get-in codes [code :number] 2))

(def- status-codes
  ``What an HTTP status raised elsewhere in the stack means to an RPC
  client. Every row is a decision:

    401  the credential was missing or bad          unauthenticated
    403  it was fine and may not do this            permission_denied
    404  no route, or the handler said so           not_found
    405/415  the transport refused the shape        unimplemented
    408/504  something ran out of time              deadline_exceeded
    409  a conflict, which for an RPC is aborted    aborted
    412  a precondition                             failed_precondition
    413/422/400  the request was wrong              invalid_argument
    429  a limiter said no                          resource_exhausted
    501  nothing implements this                    unimplemented
    502/503  the process is not serving             unavailable

  Everything else in the 4xx is invalid_argument and everything else
  in the 5xx is internal, because those are what "the caller's fault"
  and "ours" mean when nobody was more specific.``
  {400 :invalid_argument 401 :unauthenticated 403 :permission_denied
   404 :not_found 405 :unimplemented 408 :deadline_exceeded
   409 :aborted 412 :failed_precondition 413 :invalid_argument
   415 :unimplemented 422 :invalid_argument 429 :resource_exhausted
   499 :canceled 501 :unimplemented 502 :unavailable 503 :unavailable
   504 :deadline_exceeded})

(defn code-for-status
  "The Connect code an HTTP status raised elsewhere in the stack
  means to an RPC client."
  [status]
  (or (status-codes status)
      (cond
        (<= 400 status 499) :invalid_argument
        (<= 500 status 599) :internal
        :unknown)))

# -- errors as values ----------------------------------------------------

(def key
  "The key that marks a raised value as an RPC failure."
  :void.grpc/code)

(defn error-value
  ``Build an RPC failure:

      (codes/error-value :not_found "no order A-1")
      (codes/error-value :invalid_argument "quantity must be positive"
                         {:details [{:type "shop.orders.BadField" :value {:field "quantity"}}]})

  It carries `:http/status` as well, so a renderer that has never
  heard of Connect still answers with the right status.``
  [code message &opt opts]
  (default opts {})
  (unless (code? code)
    (errorf "void/grpc: %q is not a Connect code (%s)"
            code (string/join (map string names) " ")))
  # an error envelope (void/core/errors) with the Connect code beside
  # the kind; :details and :headers stay at the top, where the
  # transport reads them, and in :data, where an envelope reader looks
  (def status (get opts :http/status (http-status code)))
  (freeze (merge (errors/make :void.grpc/failed message opts status)
                 opts
                 {key code
                  :status status
                  :http/status status})))

(defn fail!
  ``Raise an RPC failure — what a handler calls instead of returning:

      (grpc/fail! :not_found "no order A-1")

  Everything else a handler can raise reaches the client too (an
  `abort` from void/authz, a panic, a schema violation); this is the
  one that names the code itself.``
  [code message &opt opts]
  (error (error-value code message opts)))

(defn failure
  ``The RPC failure inside a raised value, or nil. Reads three shapes:
  one of ours, an HTTP abort from anywhere else in void
  (`{:http/status 403}`), and a bare string from a panic — which is
  `internal`, because a message nobody designed is not a contract.``
  [err &opt panic-message]
  (cond
    (and (dictionary? err) (err key)) err
    (and (dictionary? err) (or (int? (err :http/status)) (errors/error? err)))
    (let [env (errors/of err)]
      (error-value (code-for-status (errors/status env))
                   (or (get env :message) (get err :detail) "")
                   (tabseq [k :in [:details] :when (err k)] k (err k))))
    (dictionary? err) nil
    (error-value :internal (or panic-message (string err)))))

(errors/define! :void.grpc/failed
  {:doc "an RPC failure: the Connect code under :void.grpc/code, :details for the client"})
