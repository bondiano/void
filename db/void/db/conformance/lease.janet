### void/db/conformance/lease — what a lease table does on an engine.
###
### void/db/lease is one module, but the promise it makes — one holder
### at a time, renewable, stealable once expired, askable from inside a
### transaction, and a race on the first take that one side loses
### quietly — is kept by the engine under it: by how an UPDATE's WHERE
### is re-evaluated against a row another connection just wrote, by
### what a primary-key violation does to the transaction it happens in.
### Those differ between sqlite, Postgres and MySQL, so the assertions
### are written once here and each driver's own test hands them a
### driver, the way it hands void/db/conformance/driver one:
###
###     (import void/db/conformance/lease :as lease-conformance)
###     (lease-conformance/run! "sqlite" (sqlite/make {:path file}))
###
### It ships with void/db, next to the module it checks, so a driver
### written outside this repository can prove the two plugins that
### lease — void/jobs-db, void/bus-db — will arbitrate correctly on it.

(import ../driver :as driver)
(import ../lease :as lease)
(import ../pool :as pool)
(import ../state :as db)

(defn run!
  ``Assert that void/db/lease keeps its promise over `drv0`. `name`
  names the engine in the failure messages.

  The suite makes its own table (`void_lease_conformance_<pid>`) and
  drops it on the way out; the database is otherwise untouched, so it
  can share one with a package's other suites.

  opts:
    :racers  how many fibers ask for one fresh lease at once (default
             6; 0 skips the race — for a driver whose connections
             cannot be used concurrently)``
  [name drv0 &opt opts]
  (default opts {})
  (def drv (driver/normalize drv0))
  (defn note [msg] (string name ": " msg))
  (def table (string "void_lease_conformance_" (os/getpid)))
  (def racers (get opts :racers 6))
  (def p (pool/make drv {:size (max 2 racers) :checkout-timeout 5}))

  (defn drop-table! []
    (db/run {:drop-table table :if-exists true} {:prepared false}))

  (defer (do (with-dyns [db/pool-dyn p] (drop-table!))
             (pool/close-all! p))
    (with-dyns [db/pool-dyn p]
      (drop-table!)
      (lease/create-table! table)
      (lease/create-table! table)
      (assert (nil? (lease/holder table "never"))
              (note "the table can be created twice, and an untaken lease has no holder"))

      # -- one holder at a time ----------------------------------------

      (def t 1000)
      (assert (lease/acquire! table "l" "a" t 30) (note "a free lease can be taken"))
      (assert (not (lease/acquire! table "l" "b" t 30)) (note "and not by two at once"))
      (assert (lease/acquire! table "l" "a" (+ t 10) 30)
              (note "the holder renews it with the same call"))
      (def h (lease/holder table "l"))
      (assert (= "a" (string (get h :token))) (note "the holder is who the table says"))
      (assert (= (+ t 40) (get h :until))
              (note "and a renewal moved the deadline, from now, not from the old one"))
      (assert (not (lease/acquire! table "l" "b" (+ t 39) 30))
              (note "one second before the deadline it is still held"))

      # -- release ------------------------------------------------------

      (assert (not (lease/release! table "l" "b"))
              (note "a release by somebody else changes nothing"))
      (assert (lease/holder table "l") (note "and the holder keeps the lease"))
      (assert (lease/release! table "l" "a") (note "the holder releases it"))
      (assert (nil? (lease/holder table "l")) (note "a released lease has no row"))
      (assert (lease/acquire! table "l" "b" t 30) (note "and the next taker gets it"))

      # -- expiry --------------------------------------------------------

      (assert (lease/acquire! table "l" "c" (+ t 30) 30)
              (note "at its deadline a lease is free to steal"))
      (assert (not (lease/acquire! table "l" "b" (+ t 31) 30))
              (note "the old holder cannot renew a lease that was stolen"))
      (assert (not (lease/release! table "l" "b"))
              (note "nor release it"))

      # -- prune ---------------------------------------------------------

      (lease/acquire! table "old" "x" 0 1)
      (lease/acquire! table "live" "y" t 30)
      (assert (= 1 (lease/prune! table t))
              (note "prune deletes the leases whose deadline passed before the horizon"))
      (assert (nil? (lease/holder table "old")) (note "the expired one is gone"))
      (assert (lease/holder table "live") (note "the live one stays"))
      (assert (lease/holder table "l") (note "and so does the one held past the horizon"))

      # -- from inside a transaction ---------------------------------------
      #
      # The two plugins ask for a lease from wherever they are, and on
      # Postgres a failed statement poisons the transaction it is in:
      # a take that lost on the primary key must not leave the caller's
      # transaction unusable.

      (def outcome
        (db/with-tx*
          {}
          (fn asking-inside []
            (def got (lease/acquire! table "l" "d" (+ t 31) 30))
            (db/execute! {:insert table :values {:name "after" :token "z" :until t}})
            got)))
      (assert (not outcome) (note "a held lease is refused from inside a transaction"))
      (assert (lease/holder table "after")
              (note "and the transaction it was asked in carried on"))

      (assert (= "d" (string (get (db/with-tx*
                                    {}
                                    (fn taking-inside []
                                      (lease/acquire! table "tx" "d" t 30)
                                      (lease/holder table "tx")))
                                  :token)))
              (note "a first take inside a transaction is visible to that transaction"))
      (assert (lease/holder table "tx") (note "and committed with it"))

      # -- the race on the first take --------------------------------------
      #
      # N connections insert the same fresh name at once: the primary
      # key lets one through, and every loser reads a unique violation
      # as "somebody else has it" — false, no error, no poisoned
      # connection.

      (when (pos? racers)
        (def answers (ev/chan racers))
        (each i (range racers)
          (ev/go (fn racer []
                   (ev/give answers
                            (protect (lease/acquire! table "race" (string "r" i) t 30))))))
        (def results (seq [_ :range [0 racers]] (ev/take answers)))
        (assert (all |(get $ 0) results)
                (note (string "no racer saw an error: "
                              (string/join (map |(describe (get $ 1))
                                                (filter |(not (get $ 0)) results))
                                           "; "))))
        (assert (= 1 (length (filter |(get $ 1) results)))
                (note "and exactly one of them holds the lease"))
        (assert (lease/holder table "race") (note "which the table agrees with")))))

  (printf "void/db/lease conformance (%s) OK" name)
  nil)
