# The two tables void/auth-db owns — API tokens and the single-use
# challenges behind a magic link. They are not this application's, and the
# plugin ships their DDL as data rather than as a migration of its own,
# because a migration timeline belongs to the application. The
# `customers` table stays ours: [:auth-db :users] in config/default.janet
# says which columns it reads.

(import void/auth/db :as auth-db)

(defn up []
  [;(auth-db/tables)])

(defn down []
  [;(auth-db/drop-tables)])
