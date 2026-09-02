### hub/shared/values — the two or three things that belong to no
### module.
###
### A timestamp is the whole of it today, and it is here rather than in
### a module because both the accounts table and the deliveries table
### write one, in the same shape, for the same reason: text on every
### engine, which is what keeps a migration one portable file.

(defn iso-now
  "An ISO-8601 UTC timestamp — what every `*-at` column in this
  application holds."
  []
  (def d (os/date (os/time) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))
