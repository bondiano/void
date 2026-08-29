(import ../test-support/paths)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)

# -- the three the plugin ships ------------------------------------------

(def by-name (tabseq [c :in codec/builtin] (c :name) (codec/normalize c)))
(assert (deep= @[:jdn :json :raw] (sorted (keys by-name)))
        "the package ships :json, :jdn and :raw")

(def value {:id 42 :tags ["a" "b"] :nested {:ok true}})

# jdn round-trips everything, and is the only one that does
(def j (by-name :jdn))
(assert (deep= value (codec/decode-body j (codec/encode-body j value)))
        "jdn brings a keyword-keyed table back keyword-keyed")

# json is the interchange trade, stated rather than discovered
(def js (by-name :json))
(def back (codec/decode-body js (codec/encode-body js value)))
(assert (= 42 (get back "id")) "json keys come back strings")
(assert (nil? (get back :id)) "which is the whole of the trade")

# raw is not a codec so much as the absence of one
(def r (by-name :raw))
(assert (= value (codec/decode-body r (codec/encode-body r value)))
        "raw hands the value straight through")
(assert (not (r :bytes?)) "and says out loud that it produces no bytes")

# -- nil is absence, not a value to decode -------------------------------

(each name [:json :jdn :raw]
  (assert (nil? (codec/decode-body (by-name name) nil))
          (string/format "%q leaves a missing payload missing" name)))

# -- meta comes back keyword-keyed whatever the codec --------------------
#
# meta is the one part of a message void itself reads, so its own keys
# have to survive a codec that does not keep keywords.

(def meta {:published-at 1 :correlation-id "c" :tenant "acme"})
(each name [:json :jdn]
  (def c (by-name name))
  (def m (codec/decode-meta c (codec/encode-meta c meta)))
  (assert (= "c" (get m :correlation-id))
          (string/format "%q: the framework's meta keys are keywords again" name))
  (assert (= "acme" (get m :tenant))
          (string/format "%q: and so is an application's" name)))

# -- a bad codec is refused where it is declared -------------------------

(assert (not (first (protect (codec/normalize {:name :half :encode string}))))
        "a codec without a :decode is not a codec")
(assert (not (first (protect (codec/normalize {:encode string :decode parse}))))
        "and one without a name cannot be picked by one")

(assert (not (first (protect (codec/find-codec by-name :protobuf))))
        "an unknown codec is an error, not a silent fallback")
(assert (string/find "jdn"
                     (string (last (protect (codec/find-codec by-name :protobuf)))))
        "and the error lists what there is")

# -- :raw against a backend that stores bytes ----------------------------

(def bytes-backend
  (backend/normalize {:name :db :encoded? true
                      :publish! (fn [_]) :consume! (fn [_ _]) :stop! (fn [_])}))
(def heap-backend
  (backend/normalize {:name :memory :encoded? false
                      :publish! (fn [_]) :consume! (fn [_ _]) :stop! (fn [_])}))

(assert (codec/check-compatible! r heap-backend)
        ":raw is exactly right for an in-heap backend")
(def [ok err] (protect (codec/check-compatible! r bytes-backend)))
(assert (not ok) "and impossible for one that stores bytes")
(assert (string/find "[:bus :codec]" (string err))
        "the error names the config line that fixes it")
(assert (codec/check-compatible! js bytes-backend))

(print "void/bus/codec tests OK")
