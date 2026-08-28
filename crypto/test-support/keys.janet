# Throwaway key pairs for the signature suite — generated once with
# `openssl genrsa` / `openssl ecparam`, used by nothing but these tests,
# and safe to regenerate at any time. They are checked in on purpose:
# the alternative is either shelling out to the openssl binary (a
# dependency the suite does not otherwise have) or binding EVP key
# generation (bindings the package does not otherwise need), and a
# fixture that is public by construction is neither a secret nor a
# temptation.

(def rsa-private
  ``RSA-2048 private key (PKCS#1), test fixture.``
  ``-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCnwHA221MSokKq
46Bacmn7dq5VSyMvdyGrjNqKXJkx6c40h+sYvYAOkgqqj+nwyQhKieIdP0pZIXed
z/n3dn/yPk3c9mS0NaPdxAr5n7AaGsiy7OZpBwzcKKVhHYW/VhM5XZ5XeK+07ubY
HAzHOZsLPSLjBlXZFLyTFVN7MyqvKv9YdIsb4Bz9asWCae+57PrasNOhSdfhVjt5
Lh/0bIM+npPOpIhGGzE4HDEgj9AeapAbNiiXCBp07ws1oGB70CuvyWMdP3EEpWRz
zRubZ/qAReid11yZx0HaBKGUKWXT4789cJ9deiDCC4vHwBcHOeUZzGltEzgQFK5y
OtfA31/9AgMBAAECggEAMBFRVja0cCN0jPkaqrAcNEUGoUQdee1eBYUf3gO4lffT
8XN85yLtvb8VNVh1hVxlds5Zr13CVRXk66B7lPAsq2I093rW0liIcvRI3MxoLqK8
HaEKSNAPXEp9UP2fpHrqmUZ9J71aQ7MtDIHFG5UjGy5Sf9EB6mkpu8+hkyzPL0/g
jl5/iPedOmkGiuocKC0WtUCaM/7vCNTSN2+TGDns4iE+sI3AemMOdC0xx6CcrZbc
8mkLxCxREvdiUeaIpnIalHSMeVo6/ATCSOusTvITC8w13NpY8R5PeZPa5/LW7yQW
qfHbAdCZluuRLBFpYnc7nPtvGgQgu3vgZpi0eOI8FQKBgQDidb5mNScsZxCwloAb
PcMoIWQHEgvOvIY7jhaSNyTBxZENtUW65G9JPA3Fy6k8JlqDJ614FqloL980rund
5Z9Q4aNmFMM6TxJE631+S71dJT115JW8SzU8EU+caEPjTUhPS6PAS2OWLPv8VJTh
++Kg6z0TAkR9pjoSYeirw8rV3wKBgQC9ojrv64TZKrHOTquOky9VB6Pqo0Qn+6+b
2qeEQQkkLufAVryXekw1wN6xf89GvVPdHK0ZSiBFW53zRdNOutnvZV6COLhaxt0n
4TiZorx1mw9nvDYxCL4Z6B/8YZ/rOMRIO7wJRFeFUClIfEDnUJyO17/FlQKFQMWM
o6SsWv8towKBgDBaJYobJT8Uznp11+p5GHc0EfB0iPLeS+bhYq5becypy1va7YWH
Cr/fQ62M25iNM9w3F5HBfPBS8FyGUEbhpU+WrdW47yo/Ac6XXVcfAtKlhebrJJFs
mXQ22gGyPXSF5r+Pjeob7qp89lydDqDlsDDdqU+qt0cAu/t6zjwGdQOPAoGBAKDA
HBvzV2tMUOulLrKuvCnlTyOBAS6voR6KDQUEqH4esOAP5tC1oFLUyzJGOOwrZCME
wwu0FYUV8+AcKdMMe9/+202iTUzOVP0QY42BMSa0qitylbGdSqDlb+/exdR9C457
7JsibtqYqFZE1jP/1qcT5wHTng5daNkeg2KDxNrnAoGAMyF77qLiAumtslTNj74S
FBb7I78FnRDXnE7zEh9WNwBqQWerghzbWC/SBi8maTfMSnZgpylPa9KMV5D11gpu
Rhl01OQoowb6fp0Z96XVjZC0svaPl8LTfONSB8Sf9wSd/8NtQU2uC2HVXLJuEyiL
yU0T73q+YiioJ4IMnmdsn0I=
-----END PRIVATE KEY-----``)

(def rsa-public
  ``The matching RSA public key (SubjectPublicKeyInfo).``
  ``-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAp8BwNttTEqJCquOgWnJp
+3auVUsjL3chq4zailyZMenONIfrGL2ADpIKqo/p8MkISoniHT9KWSF3nc/593Z/
8j5N3PZktDWj3cQK+Z+wGhrIsuzmaQcM3CilYR2Fv1YTOV2eV3ivtO7m2BwMxzmb
Cz0i4wZV2RS8kxVTezMqryr/WHSLG+Ac/WrFgmnvuez62rDToUnX4VY7eS4f9GyD
Pp6TzqSIRhsxOBwxII/QHmqQGzYolwgadO8LNaBge9Arr8ljHT9xBKVkc80bm2f6
gEXonddcmcdB2gShlCll0+O/PXCfXXogwguLx8AXBznlGcxpbRM4EBSucjrXwN9f
/QIDAQAB
-----END PUBLIC KEY-----``)

(def ec-private
  ``P-256 private key, test fixture.``
  ``-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIAWgBmJCOToEi7YWnjjyKwlvZjHoA8Hb4LM4tV8yJ2dmoAoGCCqGSM49
AwEHoUQDQgAEKFESiLA/xdWU1ICoGgMbwt1NZ3uSwMqW4qNSAELC8CbyZNWVyxNE
hFN8f+fxKeji19j5IwnUTQgrp1EOtCMO9w==
-----END EC PRIVATE KEY-----``)

(def ec-public
  ``The matching P-256 public key.``
  ``-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKFESiLA/xdWU1ICoGgMbwt1NZ3uS
wMqW4qNSAELC8CbyZNWVyxNEhFN8f+fxKeji19j5IwnUTQgrp1EOtCMO9w==
-----END PUBLIC KEY-----``)

