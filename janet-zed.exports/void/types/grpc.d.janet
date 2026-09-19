# Types of void/grpc's values, named where they recur.

# One of the sixteen Connect/gRPC codes (codes.janet `codes`).
(def GrpcCode :typedef
  '(enum :canceled :unknown :invalid_argument :deadline_exceeded :not_found
         :already_exists :permission_denied :resource_exhausted :failed_precondition
         :aborted :out_of_range :unimplemented :internal :unavailable :data_loss
         :unauthenticated))

# An RPC failure: the frozen error envelope `codes/error-value` builds (void/core/errors), the
# code beside the kind and the status both ways — plus the caller's :details and :headers.
(def GrpcFailure :typedef
  '{:void.grpc/code GrpcCode :status :number :http/status :number & r})

# What a caller adds to a failure: `codes/error-value` and `fail!` merge it in.
(def GrpcFailureOptions :typedef
  '{:http/status :number? :details (or [:any] :nil) :headers (or @{:string :string} :nil) & r})
