# Wave 3: the authors table gains a password hash, and the blog gets a
# login. The column is nullable on purpose — the rows that exist were
# created by the wave-2 flow, where publishing an article invented an
# author on the spot, and an author with no password simply cannot sign
# in (void/auth's password strategy answers :no-password, after
# spending the same time it would have spent on a real check).
#
# The hash is a PHC string, so the column is text and its length is
# whatever the configured hasher writes — the parameters travel inside the
# value.

# The other two tables are not this application's at all: they are
# void/auth-db's, and it ships their DDL as data rather than as a
# migration of its own, because a migration timeline belongs to the
# application. The blog does not issue API tokens or magic links yet — it
# composes the stores, so the tables exist, and the day it wants either
# there is nothing to remember.
(import void/auth/db :as auth-db)

(defn up
  {:params [] :ret [{:keyword :any}]}
  "Add the password column authors sign in with, and bring in
  void/auth-db's own tables since this application composes its
  stores rather than migrating them separately."
  []
  [{:alter-table "authors"
    :add-column [:password-hash :text]}
   ;(auth-db/tables)])

(defn down
  {:params [] :ret [{:keyword :any}]}
  "Drop void/auth-db's tables and the password column, in that order
  since neither depends on the other."
  []
  [;(auth-db/drop-tables)
   {:alter-table "authors"
    :drop-column :password-hash}])
