(declare-project
  :name "void-oauth"
  :description "void/oauth — \"sign in with a provider\": the OAuth 2.1 / OIDC client — authorization code + PKCE, the pending flow in the session, the id_token verified against the issuer's JWKS, and the verified visitor handed to the application's :void.oauth/sign-in."
  :version "0.0.1")

# The client half of what the resource server started: void/auth is here for the
# jwk/jwt modules (the id_token is verified with the same code that
# verifies an access token) and for auth-http/login!; void/http for the
# routes and the back-channel client; void/crypto for PKCE, state and
# the signature primitives under jwt.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
