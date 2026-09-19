# Types of void/jobs's values, named where they recur.

# A retry backoff policy after `job/normalize-backoff`.
(def JobsBackoff :typedef
  '{:strategy :keyword :base :number :max :number :jitter :number})

# A queued job: the table `record/make` builds and every backend stores, claims and settles.
# `:token` is the claiming worker's id, `:inline` for a job run in the enqueuing fiber.
(def JobsRecord :typedef
  '@{:id :string :job :keyword :args [:any] :queue :keyword :priority :number
    :state (enum :pending :running :waiting :completed :dead)
    :attempt :number :max-attempts :number :backoff JobsBackoff? :timeout :number?
    :run-at :number :enqueued-at :number :started-at :number? :finished-at :number?
    :unique-key :string? :unique-until :number? :group :string?
    :parent :string? :children-left :number?
    :children (or @[{:id :string :job :keyword :result :any}] :nil)
    :result :any :error :string? :failures @[:any]
    :token (or :string :inline :nil) :traceparent :string? & r})

# A :void/jobs-backend after `backend/normalize` (the contract is void/jobs/backend's
# docstring): every optional key filled in, plus anything of the backend's own — hence open.
(def JobsBackend :typedef
  '{:name :any :shared? :boolean :transactional? :boolean
   :push! (fn [JobsRecord] JobsRecord?)
   :claim! (fn [{:queues [:keyword] :now :number :token :string & r}] JobsRecord?)
   :settle! (fn [JobsRecord & :string] JobsRecord?)
   :fetch (fn [:string] JobsRecord?)
   :list (fn [{:keyword :any}] [JobsRecord])
   :counts (fn [] {:keyword {:keyword :number}})
   :remove! (fn [:string] :boolean)
   :clear! (fn [{:keyword :any}] :number)
   :reap! (or (fn [{:now :number :ttl :number :token :string & r}] [JobsRecord]) :nil)
   :touch! (or (fn [[:string] :number & :string] :number) :nil)
   :release-parent! (or (fn [JobsRecord] JobsRecord?) :nil)
   :rate-take! (fn [:keyword :number :number :number] :number)
   :lock! (fn [:any :number :string] :boolean)
   :unlock! (fn [:any :number :string] :boolean)
   :shared-rate? :boolean :shared-locks? :boolean
   :stats (fn [] :any) :close (fn [] :any) & r})

# The per-queue defaults a queue value resolves every enqueue against.
(def JobsDefaults :typedef
  '{:queue :keyword :priority :number :max-attempts :number :backoff :any
   :timeout :number? :claim-ttl :number & r})

# A queue value: the table `state/make` builds over a normalized backend — what the
# :jobs/queue component holds and every enqueue runs against.
(def JobsQueue :typedef
  '@{:backend JobsBackend
    :config {:keyword :any} :queues {:keyword :any}
    :defaults JobsDefaults
    :stats @{:enqueued :number :duplicates :number}})
