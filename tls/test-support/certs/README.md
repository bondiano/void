# Test certificate

A self-signed certificate for the suite's TLS servers — `CN=localhost`,
SAN `DNS:localhost, IP:127.0.0.1`, EC P-256, valid for twenty years so
nobody debugs an expired fixture. The private key is committed on
purpose: it protects nothing, it *is* the fixture.

Regenerate with:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout server-key.pem -out server-cert.pem -days 7300 -nodes \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```
