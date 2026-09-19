# Types of void/security's values, named where they recur.

# The store the rate limiter counts in: the part of a `:void/cache-store` it calls
# (`limit/memory-store`, or the cache's own store) — hence open.
(def SecurityRateStore :typedef
  '{:get (fn [:string] :any) :incr (fn [:string :number :number] :number) & r})
