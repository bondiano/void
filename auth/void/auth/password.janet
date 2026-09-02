### void/auth/password — the login form's half (ADR-0023 §3, §4).
###
### The strategy with a `:verify` and no `:authenticate`: a password is
### never carried by a request the way a cookie or a token is, so this
### never runs on the hot path. It runs once, when somebody submits a
### form, and it is allowed to spend 25 ms doing it.
###
### Two things this module does that a three-line version would not:
###
### **It hashes even when the user does not exist.** `hash/dummy-verify`
### spends the same time on nothing, because a login form that answers
### in 200 µs for unknown addresses and 25 ms for known ones is a
### user-enumeration API with a nice UI.
###
### **It rehashes on the way through.** When the stored hash was
### written with an older algorithm or a lower cost, and the user store
### can write (`:update-secret`), the new hash is stored right there —
### the successful login is the only moment when the plaintext exists,
### so it is the only moment a rehash is possible. A store that cannot
### write simply keeps its old hashes, and `:needs-rehash` in the
### result says so.

(import void/core/log :as log)
(import ./hash :as hash)
(import ./identity :as identity)

(def log-ns "void.auth.password")

(def selectors
  ``The `:by` values a login is allowed to look a user up with.
  Closed on purpose: `credentials` is very often `(req :form)`, so an
  open `:by` would let a visitor pick the WHERE column of the user
  query — `by=role&value=admin` finds somebody by privilege, and a
  column that does not exist turns the login form into a
  schema-probing oracle through the driver's error.``
  [:email :username :subject :id])

(defn check
  ``Verify credentials against a user store. Returns

      {:identity id|nil :needs-rehash bool :record rec|nil :reason kw}

  `:reason` is :ok, :no-such-user, :no-password, :bad-password or
  :bad-selector — for the log and for a rate limiter, never for the
  response body: telling a visitor which of them it was is the
  enumeration this module spends 25 ms avoiding.

  Credentials: `{:by :email :value "a@b.c" :password "..."}`, or
  `{:email ... :password ...}` for the common case — `:by` must be one
  of `selectors`, because a form field must not choose the lookup
  column. String keys are accepted, so a submitted form goes straight
  in.``
  [store credentials0 &opt opts]
  (default opts {})
  # a login form arrives from void/http as string keys; every other
  # caller writes keywords. Keywordizing here is the difference between
  # `(auth/check-password store (req :form))` working and being a
  # papercut in every application
  (def credentials
    (tabseq [[k v] :pairs (or credentials0 {})]
      (if (bytes? k) (keyword k) k) v))
  (def by (or (credentials :by)
              (cond
                (credentials :email) :email
                (credentials :username) :username
                :subject)))
  (def value (or (credentials :value)
                 (credentials by)
                 (credentials :subject)))
  (def password (or (credentials :password) ""))
  (def now (get opts :now (os/time)))
  # the whitelist gates the *lookup*: a store never sees a selector a
  # form invented, and the refusal still burns the hash time so that
  # a probed selector answers in the same 25 ms an unknown user does
  (def record (when (and value (index-of by selectors))
                ((store :find) {:by by :value value})))
  (def secret (when record ((store :secret) record)))
  (cond
    (not (index-of by selectors))
    (do (hash/dummy-verify password)
        (log/debug "login with a selector outside the whitelist" :ns log-ns :by by)
        {:identity nil :needs-rehash false :record nil :reason :bad-selector})

    (nil? record)
    (do (hash/dummy-verify password)
        {:identity nil :needs-rehash false :record nil :reason :no-such-user})

    (nil? secret)
    (do (hash/dummy-verify password)
        {:identity nil :needs-rehash false :record record :reason :no-password})

    (let [[ok rehash?] (hash/verify password secret)]
      (if (not ok)
        {:identity nil :needs-rehash false :record record :reason :bad-password}
        (do
          (when (and rehash? (store :update-secret))
            (def [written err] (protect ((store :update-secret) record (hash/hash password))))
            (if written
              (log/info "password rehashed on login" :ns log-ns
                        :subject ((store :subject) record) :hasher (hash/active-hasher))
              (log/warn "password rehash failed" :ns log-ns :err (string err))))
          {:identity (identity/make ((store :subject) record)
                                    {:via :password
                                     :cookie false
                                     :claims ((store :claims) record)
                                     :at now})
           :needs-rehash rehash?
           :record record
           :reason :ok})))))

(defn strategy
  ``The :password strategy over a user store — `:verify` only, so it
  is never in the per-request chain.``
  [store]
  {:name :password
   :doc "Email/username and password, checked against the user store; hashes even for unknown users so that timing does not enumerate accounts"
   :verify (fn password-verify [credentials]
             (get (check store credentials) :identity))})
