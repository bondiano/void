(import ../test-support/paths)
(import void/crypto/lib :as lib)
(import void/crypto/kdf :as kdf)
(import void/crypto/encode :as encode)

(lib/load!)

(assert kdf/in-thread
        "derivation goes to a worker thread by default — 25 ms on the ev loop is 25 ms of a worker answering nobody (ADR-0022 §5)")

(set kdf/in-thread false)

# -- scrypt, RFC 7914 §12 ------------------------------------------------

(assert (= (string "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2"
                   "d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887")
           (encode/hex (kdf/scrypt "pleaseletmein" "SodiumChloride"
                                   {:n 16384 :r 8 :p 1 :length 64}))))

(assert (= (string "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
                   "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
           (encode/hex (kdf/scrypt "password" "NaCl" {:n 1024 :r 8 :p 16 :length 64})))
        "p > 1 is a different code path inside scrypt, and the vector pins it")

# -- PBKDF2, RFC 6070 ----------------------------------------------------

(assert (= "0c60c80f961f0e71f3a9b524af6012062fe037a6"
           (encode/hex (kdf/pbkdf2 "password" "salt"
                                   {:iterations 1 :length 20 :digest :sha1}))))
(assert (= "4b007901b765489abead49d926f721d065a429c1"
           (encode/hex (kdf/pbkdf2 "password" "salt"
                                   {:iterations 4096 :length 20 :digest :sha1}))))

# -- argon2id, RFC 9106 §5.3 --------------------------------------------

(if (kdf/available? :argon2id)
  (do
    (assert (= "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"
               (encode/hex (kdf/argon2id (string/repeat "\x01" 32)
                                         (string/repeat "\x02" 16)
                                         {:t 3 :m 32 :lanes 4 :length 32
                                          :secret (string/repeat "\x03" 8)
                                          :ad (string/repeat "\x04" 12)})))
            "the RFC vector, pepper and associated data included")
    (assert (not= (kdf/argon2id "pw" "saltsaltsaltsalt" {:t 1 :m 32 :length 32})
                  (kdf/argon2id "pw" "saltsaltsaltsalt"
                                {:t 1 :m 32 :length 32 :secret "pepper"}))
            "and a pepper changes the answer — which is its whole job")

    # A salt is random bytes, and about one random salt in sixteen
    # contains a zero. An OSSL_PARAM carries a pointer and a length, so
    # zeroes are none of its business — but a parameter written as a C
    # string ends at the first one, and this used to fail for one
    # password in sixteen and no other reason (see kdf/ossl-params).
    (each [name salt]
      [["a zero inside" "salt\0with\0zeroes"]
       ["a leading zero" "\0saltsaltsaltsal"]
       ["a trailing zero" "saltsaltsaltsal\0"]]
      (def out (kdf/argon2id "pw" salt {:t 1 :m 32 :length 32}))
      (assert (= 32 (length out)) (string "a salt with " name " derives a key"))
      (assert (not= out (kdf/argon2id "pw" (string/replace-all "\0" "x" salt)
                                      {:t 1 :m 32 :length 32}))
              (string "and the zeroes are part of it: " name " is not truncated"))))
  (do
    (def [ok err] (protect (kdf/argon2id "pw" "saltsaltsaltsalt")))
    (assert (not ok) "without OpenSSL 3.2 argon2id is an error, never a silent fallback")
    (assert (string/find "3.2" (string err))
            "and the message says what would fix it")
    (printf "SKIP argon2id: %s has no ARGON2ID (needs OpenSSL 3.2)" (lib/version-text))))

# -- parameters that cannot work fail, they do not return rubbish --------

(each [opts reason]
  [[{:n 16385} "an N that is not a power of two"]
   [{:n 1} "an N of 1"]
   [{:n 1048576 :maxmem 1024} "a memory limit below what N and r need"]]
  (def [ok] (protect (kdf/scrypt "pw" "saltsalt" opts)))
  (assert (not ok) (string reason " is an error")))

(def [ok] (protect (kdf/pbkdf2 "pw" "salt" {:digest :sha3})))
(assert (not ok) "so is an unknown digest")

# -- the thread and the loop (ADR-0022 §5) -------------------------------

(def opts {:n 16384 :r 8 :p 1 :length 32})
(def inline-hash (kdf/scrypt "hunter2" "saltsaltsaltsalt" opts))

(defn- ticks-during
  ``Run `thunk` with a 2 ms ticker on the loop and report how many
  times the loop got to run it. The ticker stops on a flag rather than
  on ev/cancel: cancelling a sleeping fiber unwinds it with an error
  the supervisor prints, and a test that passes should say nothing.``
  [thunk]
  (var ticks 0)
  (var running true)
  (ev/go (fn [&] (while running (ev/sleep 0.002) (++ ticks))))
  (ev/sleep 0.01)
  (set ticks 0)
  (def out (thunk))
  (set running false)
  [out ticks])

(def [on-loop loop-ticks]
  (ticks-during (fn [] (kdf/scrypt "hunter2" "saltsaltsaltsalt" opts))))
(assert (= inline-hash on-loop))
(assert (zero? loop-ticks)
        "on the loop, nothing else runs for the whole derivation — this is the number the default exists to avoid")

(set kdf/in-thread true)
(def [in-worker worker-ticks]
  (ticks-during (fn [] (kdf/scrypt "hunter2" "saltsaltsaltsalt" opts))))
(assert (= inline-hash in-worker)
        "the worker thread computes the same bytes — it re-opens the library, so this is also the test that the re-open is the same library")
(assert (> worker-ticks 2)
        (string/format "the loop kept running during the derivation (%d ticks of 2 ms)" worker-ticks))

# an error inside the worker comes back as an error here, not as a hang
(def [ok err] (protect (kdf/scrypt "pw" "saltsalt" {:n 3})))
(assert (not ok) "a bad parameter fails through the thread boundary")
(assert (string/find "scrypt" (string err)))

(print "kdf-test ok")
