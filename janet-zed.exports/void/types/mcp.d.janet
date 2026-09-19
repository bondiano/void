# Types of void/mcp's values, named where they recur.

# A JSON-RPC 2.0 error object: `jsonrpc/fail` builds it, with :data when the refusal has one.
(def McpRpcError :typedef
  '@{:code (or :keyword :number) :message :string & r})

# A successful JSON-RPC response: the table `jsonrpc/result` builds.
(def McpResult :typedef
  '@{:jsonrpc :string :id :any :result :any})

# A JSON-RPC error response: the table `jsonrpc/fail` builds.
(def McpFailure :typedef
  '@{:jsonrpc :string :id :any :error McpRpcError})

# What a server answers a message with: a result or a refusal (nil, for a notification, is
# written beside it where it can happen).
(def McpResponse :typedef
  '(or McpResult McpFailure))

# A decoded message, as `jsonrpc/decode` hands it under :ok: a request, a notification, or a
# response the client sent.
(def McpMessage :typedef
  '{:id :any :params :any :response? :any :notification? :any :method :string? & r})
