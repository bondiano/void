### shop/shared/values — the handful of values that belong to no module.
###
### A module owns its model, its DTOs, its repository and its service
### (see the README). What is here is what all of them would otherwise
### each define: a timestamp, a random handle, an order number and the
### one function that turns money into a string.
###
### **Money is an integer number of cents.** There is no decimal type
### in this application, no float and no locale: a price is `1499`, and
### `format-price` is the only place it becomes "€14.99". A float would
### be a rounding error waiting for the order that ends in .005, and a
### string would be a number that cannot be summed.

(defn now
  ``An ISO-8601 UTC timestamp. Text on both engines, which is what
  keeps the migrations one file instead of two.``
  []
  (def d (os/date (os/time) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn timestamp-before
  ``The same stamp, `seconds` ago — what a sweep compares against.``
  [seconds]
  (def d (os/date (- (os/time) seconds) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn token
  "A URL-safe random handle — a cart's, and nothing that authenticates."
  [&opt bytes]
  (default bytes 16)
  (string/join (map |(string/format "%02x" $) (os/cryptorand bytes)) ""))

(defn order-number
  ``The number a customer quotes. Deliberately not the primary key and
  deliberately not sequential: an order number that counts tells every
  customer how many orders this shop has taken today.``
  []
  (string "SH-" (string/ascii-upper (token 4))))

(defn format-price
  ``Cents as the one string a page prints. The only place in the
  application where money stops being an integer.``
  [cents]
  (string/format "€%d.%02d" (div cents 100) (mod cents 100)))
