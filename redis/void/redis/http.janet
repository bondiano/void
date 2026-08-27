### void/redis-http — sessions in redis (SPEC.md §5.1 / §5.10,
### CONTRACTS v1 point `:void.http/session-store`).
###
### The one piece of void/redis that needs void/http, kept a separate
### plugin so a CLI or a worker process never drags the HTTP kernel in
### — exactly what void/db-http is to void/db. Add it to the
### composition and name the store:
###
###     (void/run! {:plugins [:void/http :void/redis :void/redis-http ...]})
###     # config/prod.janet
###     {:http {:session {:store :redis :ttl 86400}}
###      :redis {:url "redis://cache.internal/0"}}
###
### This is what makes `:workers :auto` and sessions coexist. An
### in-memory store lives in one process's heap, so with prefork every
### worker has a different set of sessions and a user's requests land
### in whichever worker accept() gave them — void/http refuses that
### combination at start rather than let it be discovered in
### production (ADR-0010). A shared store is the answer, and this is
### one.
###
### Two decisions worth stating:
###
### The value is jdn, not the client's `[:redis :codec]`. A session is
### a Janet table with keyword keys, and jdn is the only encoding that
### brings both halves of that back — JSON returns string keys, and
### `:raw` cannot carry a table at all. A store that quietly reshaped
### the session under a different codec would be a bug that only
### appears once someone changes an unrelated config key.
###
### The expiry is redis', not a sweep. `save` writes with the session
### TTL as SET ... EX, so an abandoned session is collected by the
### server whether or not this process is still running, and `:sweep`
### is the no-op that says so. The TTL is refreshed on every save,
### which is what makes it an idle timeout rather than an absolute
### one.

(import void/core/plugin :as plugin)
(import ./codec :as codec)
(import ./state :as state)

(def default-prefix
  "Key prefix for session ids, under whatever [:redis :prefix] the
  client adds."
  "session:")

(defn store
  ``A session store over the running redis client. Everything it needs
  — which server, which database, which key prefix, which session
  prefix ([:redis :session :prefix]) — is read from the client at
  request time rather than now, so the store is built once and
  outlives a restart of the client under it. `opts` :prefix overrides
  the configured session prefix.``
  [&opt opts]
  (default opts {})
  (defn session-key [sid]
    (def prefix (or (get opts :prefix)
                    (get (state/active-client) :session-prefix default-prefix)))
    (state/prefixed (string prefix sid)))
  {:name :redis
   :load (fn load [sid]
           (when-let [raw (state/call ["GET" (session-key sid)])]
             (def data (codec/decode codec/jdn raw))
             # the middleware mutates what it is given, so it has to be
             # a table: a struct decoded out of jdn would fail on the
             # first (put (req :session) ...)
             (if (table? data) data (table ;(kvs data)))))
   :save (fn save [sid data ttl]
           (state/call ["SET" (session-key sid)
                        (codec/encode codec/jdn data)
                        "EX" (math/round (max 1 ttl))])
           sid)
   :delete (fn delete [sid]
             (state/call ["DEL" (session-key sid)])
             nil)
   # redis expires keys itself, on its own clock, whether or not this
   # process is running — there is nothing to sweep
   :sweep (fn sweep [] nil)})

(plugin/defcontribution :void.http/session-store
  {:name :redis
   # nothing is read from the http session slice here: the ttl arrives
   # with each save, and the key prefix belongs to [:redis :session],
   # where the rest of this plugin's configuration lives
   :make (fn make-store [_session-config] (store))})

(plugin/defplugin void/redis-http
  :doc "Sessions in redis: the :redis session store for void/http, which is what lets sessions and prefork workers coexist (ADR-0010)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/redis ">=0.0.1" :void/http ">=0.0.1"})
