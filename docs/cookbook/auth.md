# Auth: passwords, magic links, API tokens

`void/auth` keeps identity as data in a dyn —
`{:subject "user:42" :via :password :claims {…}}` — and does not know
what a user is. The three recipes below are the three common shapes on
top of it, each verified against a shipped example.

## Start with the scaffold

```sh
void make auth
```

writes the five pages every application used to write by hand —
register, sign in, sign out, password reset, address verification —
plus the users migration and a suite that drives all of them
([Getting started §6](../GETTING-STARTED.md)). It prints the three
edits it refuses to make for you (plugins, config, the driver
dependency) rather than rewriting your files. What follows is what the
generated code does, so you can change it with open eyes.
[examples/hub](../../examples/hub) began as exactly this scaffold, and
its first commit is the generator's raw output.

## Passwords

From [examples/blog/app.janet](../../examples/blog/app.janet) — the
whole sign-in handler:

```janet
(def result (form/check e/Credentials (req :form)))
(def check (when (empty? (result :errors))
             (auth/check-password (auth/user-store) (result :value))))
(if-let [id (get check :identity)]
  (do (auth-http/login! req id)
      (ring/redirect "/"))
  (render-form-again-with-one-vague-message))
```

Details the framework already decided for you: hashes are portable PHC
strings that carry their own cost (raising it is a config change, not
a migration); an unknown login burns the same ~25 ms as a wrong
password (`dummy-verify`), so the response does not say which it was;
and `login!` rotates the session id, because session fixation has no
other fix.

## Magic links

A magic link is a *challenge*: `challenge!` mints a single-use code,
stores its digest, and hands delivery to whoever contributed
`:void.auth/deliver` — with `void/mail-auth` composed, that is a
letter. The handler contains no template, no URL and no token:

```janet
(auth/challenge! (string "author:" (author :id))
                 {:to (author :email)
                  :claims {:name (author :name)}})
```

Redeeming takes the challenge out of the store *before* checking the
code, so a link works exactly once:

```janet
(if-let [id (auth/redeem! (get query "h") (get query "c"))]
  (do (auth-http/login! req id)
      (ring/redirect "/"))
  (say-it-expired))
```

Note the enumeration guard in the blog: the page answers "if that
address has an account, a link is on its way" whether or not it found
one. A challenge nobody would deliver is an error at the call site
(ADR-0023 §7) — composing `:void/mail-auth` or contributing your own
deliverer is required, not optional.

## API tokens

Tokens are stored as digests and verified by the `:bearer` strategy.
Mint one (from
[examples/shop/test/api-test.janet](../../examples/shop/test/api-test.janet)):

```janet
(def minted (auth/issue-token (auth/token-store)
                              (string "customer:" (ada :id))
                              {:name "api-test"}))
# (minted :token) is shown once; the store keeps only its digest
```

And gate the API routes with metadata rather than code — from
[examples/shop/src/modules/orders/orders.api.janet](../../examples/shop/src/modules/orders/orders.api.janet):

```janet
{:meta {:void.auth/access :required
        :void.auth/strategies [:bearer]}}
```

`:strategies [:bearer]` means a browser session cannot reach the API
routes and a token cannot reach the pages — and because the credential
never rides on a cookie, CSRF correctly does not apply there
(`void/security` follows the attack, not the verb).

## Where the pieces live

- Strategies (`:session`, `:bearer`, `:jwt`, `:password`, challenges)
  and the identity dyn: `void/auth` — see the
  [module reference](https://bondiano.github.io/void/modules/).
- The middleware that resolves identity, `login!`/`logout!`, and
  401-vs-redirect: `void/auth-http`.
- Database-backed user/token/challenge stores: `void/auth-db`.
- "Sign in with a provider" (OAuth/OIDC client): `void/oauth`;
  accepting OAuth access tokens as a resource server:
  `void/auth-oauth`.
