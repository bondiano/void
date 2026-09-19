# Types of void/pressure's values, named where they recur.

# Why a state sheds: a threshold crossed (`threshold-reasons`) or a custom check that said
# no (`check-reasons`); `:signal` is the signal, or the check's name.
(def PressureReason :typedef
  '(or {:signal :keyword :value :number :limit :number :bar :number}
      {:signal :keyword :check :boolean :reason :string}))

# A custom check: a `:void.pressure/check` contribution, or `add-check!`'s entry.
(def PressureCheck :typedef
  '{:name :keyword :fn (fn [] :any)})

# One set of samples the sampler feeds `observe!`: `:rss` is nil where the platform has no
# meter.
(def PressureSamples :typedef
  '{:loop-lag :number? :rss :number?})

# A pressure state: the table `state/make` builds; `start-sampler!` adds `:heartbeat` and
# the fiber `:started` — hence open.
(def PressureState :typedef
  '@{:config {:keyword :any}
    :checks @[PressureCheck]
    :under-pressure :boolean
    :reasons [PressureReason]
    :samples @{:keyword :number}
    :peaks @{:keyword :number}
    :clean :number
    :sampled :number
    :sheds :number
    :episodes :number
    :since :number
    :changed-at :number
    :sampling :boolean
    :fiber :fiber?
    :pid :number
    & r})

# What the sampler knows: the struct `state/status` answers, for `(pressure/status)`, the
# health contribution and `void pressure status`.
(def PressureStatus :typedef
  '{:under-pressure :boolean
   :mode :keyword
   :reasons [PressureReason]
   :samples {:keyword :number}
   :peaks {:keyword :number}
   :available {:loop-lag :boolean :rss :boolean :heap :boolean}
   :limits {:max-loop-lag :number? :max-rss-bytes :number?}
   :recovery {:ratio :any :samples :any :clean :number}
   :interval :any
   :sampling :boolean
   :sampled :number
   :shed :number
   :episodes :number
   :for :number
   :checks [:keyword]
   :pid :number})
