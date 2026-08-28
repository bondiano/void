# void/auth-db over the reference driver: the application's users table
# read through the store contract, and the two tables void owns —
# tokens as digests and single-use one-time codes.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/db :as db)
(import void/crypto :as crypto)
(import void/crypto/kdf :as kdf)
(import void/auth :as auth)
(import void/auth/hash :as hash)
(import void/auth/token :as token)
(import void/auth/challenge :as challenge)
(import void/auth/password :as password)
(import void/auth/db :as auth-db)

(log/set-level! "void" :error)
(crypto/load!)
(set kdf/in-thread false)
(set hash/settings {:hasher :scrypt :scrypt {:ln 10 :r 8 :p 1 :length 32 :salt-bytes 16}})

(def sandbox (string (os/cwd) "/.tmp-auth-db-" (os/time) "-" (os/getpid)))
(os/mkdir sandbox)

(def plugins ["void/db/init" "void/db-sqlite/init" "void/crypto/init"
              "void/auth/init" "void/auth/db"])

(def config
  {:env @{}
   :cli {:log {:level :error}
         # two implementations now provide each store interface — the
         # memory ones from void/auth and these — which is exactly the
         # ambiguity the kernel refuses to resolve on its own. The
         # application says which, the way it does for :void/db-driver
         # and :void/cache-store
         :void/auth-user-store {:impl :auth.db/users}
         :void/auth-token-store {:impl :auth.db/tokens}
         :void/auth-challenge-store {:impl :auth.db/challenges}
         :crypto {:kdf {:in-thread false}}
         :auth {:scrypt {:ln 10}}
         :auth-db {:users {:table "people"
                           :id-column "id"
                           :subject-kind "user"
                           :email-column "email"
                           :password-column "secret_hash"
                           :claims-columns ["role"]}}
         :db-sqlite {:path (string sandbox "/auth.sqlite3")}}})

# -- the composition -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config config}))
(assert (report :ok) "void/auth-db composes with void/auth and a driver")
(each key [:auth.db/users :auth.db/tokens :auth.db/challenges]
  (assert (index-of key (report :components))))

(def unselected
  {:env @{}
   :cli {:log {:level :error} :db-sqlite {:path (string sandbox "/x.sqlite3")}}})
(def [ambiguous err]
  (protect (plugin/dry-run {:plugins plugins :profile :test :config unselected})))
(assert (not ambiguous)
        "with both the memory and the db store on an interface, the kernel refuses to guess")
(assert (string/find "provided by multiple components" (string err))
        "and names the interface and the components that provide it")

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test :config config}))

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defer (do (plugin/shutdown! boot 3) (rimraf sandbox))

  # the application's table is the application's: void creates its own two
  (db/execute-sql "create table people (id integer primary key, email text, secret_hash text, role text)" [])
  (each stmt (auth-db/tables) (db/run stmt))

  (def stored (hash/hash "hunter2"))
  (db/execute! {:insert :people
                :values [{:id 1 :email "a@b.c" :secret_hash stored :role "admin"}
                         # db/null, not nil: janet drops a nil value from a struct
                         # literal, and a multi-row insert wants the same columns
                         # in every row
                         {:id 2 :email "b@b.c" :secret_hash db/null :role "guest"}]})

  # -- the user store ----------------------------------------------------

  (def users (auth/user-store))
  (assert (= :db (users :name)))

  (def by-email ((users :find) {:by :email :value "a@b.c"}))
  (assert by-email "found by the configured email column")
  (assert (= "user:1" ((users :subject) by-email)) "the subject is <kind>:<id>")
  (assert (= stored ((users :secret) by-email)))
  (assert (deep= {:role "admin"} ((users :claims) by-email))
          "only the columns [:auth-db :users :claims-columns] names — every one of them is read on every session request")

  (def by-subject ((users :find) {:by :subject :value "user:1"}))
  (assert (= 1 (by-subject :id)) "a subject addresses the id column by its id half")
  (assert (nil? ((users :find) {:by :subject :value "user:99"})))
  (assert (nil? ((users :find) {:by :email :value "nobody@b.c"})))
  (assert (nil? ((users :find) {:by :username :value "ann"}))
          "a column the configuration does not name cannot be searched")

  (assert (= :ok ((password/check users {:email "a@b.c" :password "hunter2"}) :reason))
          "and the password strategy works over it unchanged")
  (assert (= :bad-password ((password/check users {:email "a@b.c" :password "no"}) :reason)))
  (assert (= :no-password ((password/check users {:email "b@b.c" :password "no"}) :reason)))

  # -- the token store ---------------------------------------------------

  (def tokens (auth/token-store))
  (def issued (token/issue tokens "user:1" {:name "ci" :scopes [:read :write]}))
  (def id (get-in issued [:record :id]))

  (def row (db/one-row {:select [:*] :from :auth_tokens :where {:id id}}))
  (assert row "the token is a row")
  (assert (not (string/find (last (string/split "." (issued :token))) (string/format "%q" row)))
          "and the secret is not in it — the column holds a digest")

  (def whoami (token/verify tokens (issued :token)))
  (assert (= "user:1" (whoami :subject)))
  (assert (deep= [:read :write] (tuple ;(get-in whoami [:claims :scopes])))
          "scopes survive the round trip through JSON")
  (assert (pos? ((db/one-row {:select [:used] :from :auth_tokens :where {:id id}}) :used))
          "and the use was recorded")

  (assert (nil? (token/verify tokens (string (issued :token) "x"))))
  (assert (= 1 (length (token/list-for tokens "user:1"))))
  (assert (token/revoke tokens id))
  (assert (nil? (token/verify tokens (issued :token))))

  # -- the challenge store -----------------------------------------------

  (def codes (auth/challenge-store))
  (def link (challenge/issue codes "user:1" {:claims {:next "/admin"}}))
  (assert (= 1 (length (db/query-sql {:select [:handle] :from :auth_challenges}))))

  (def redeemed (challenge/redeem codes (link :handle) (link :code)))
  (assert (= "user:1" (redeemed :subject)))
  (assert (= "/admin" (get-in redeemed [:claims :next])))
  (assert (nil? (challenge/redeem codes (link :handle) (link :code)))
          "single-use across a real store: the read and the delete are one transaction")
  (assert (zero? (length (db/query-sql {:select [:handle] :from :auth_challenges}))))

  (def otp1 (challenge/issue codes "user:2" {:kind :otp}))
  (def otp2 (challenge/issue codes "user:2" {:kind :otp}))
  (assert (= 1 (length (db/query-sql {:select [:handle] :from :auth_challenges})))
          "re-issuing for the same subject replaces the code that was sent")
  (assert (nil? (challenge/redeem codes (otp1 :handle) (otp1 :code))))

  (def expired (challenge/issue codes "user:3" {:kind :otp :ttl -1}))
  (assert (nil? (challenge/redeem codes (expired :handle) (expired :code))))

  (def stale (challenge/issue codes "user:4" {:ttl -1}))
  (assert (pos? (length (db/query-sql {:select [:handle] :from :auth_challenges}))))
  ((codes :sweep))
  (assert (zero? (length (db/query-sql {:select [:handle] :from :auth_challenges})))
          "and `void auth sweep` clears what expired without being redeemed"))

(print "db-test ok")
