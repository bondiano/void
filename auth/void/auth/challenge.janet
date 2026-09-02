### void/auth/challenge — magic links and one-time codes
### (ADR-0023 §7).
###
### One flow, two spellings:
###
###   :link  a long random code in a URL, mailed to an address
###   :otp   six digits, mailed or texted, typed by a human
###
### Both are "prove you control this address": something is issued
### against a handle, delivered out of band, and redeemed once.
###
### **Delivery is not this module's business.** It generates, stores a
### digest and redeems; getting the code to the person is a
### `:void.auth/deliver` contribution, which `void/mail` (3.5) will be
### one of. Without that, 3.2 would have been blocked on 3.5 for no
### architectural reason at all — and an application that sends its own
### SMS never wants void's mailer anyway.
###
### **A code is single-attempt.** `redeem` takes the record out of the
### store *before* it checks the code (the store contract has no other
### way to be atomic — see ./store), so a wrong digit invalidates the
### challenge and the visitor asks for another. With six digits that
### makes a guess a one-in-a-million shot per issuance; allowing three
### attempts would triple those odds and would need a mutable counter
### in a contract that deliberately does not have one. Re-requesting a
### code is cheap; being brute-forced is not.
###
### The stored record holds a **digest** of the code, so the store's
### contents cannot be replayed as codes.

(import void/crypto/digest :as digest)
(import void/crypto/random :as random)
(import void/crypto/encode :as encode)
(import void/crypto/ct :as ct)
(import ./identity :as identity)

(def defaults
  ``How a challenge is shaped.

  `:ttl` 900 — fifteen minutes is long enough to walk to another
  device for the mail and short enough that a link found later in a
  shared inbox is dead. `:otp-digits` 6 is what people expect to
  type; `:link-bytes` 32 is 256 bits, because a link is not typed by
  anybody and has no reason to be short.``
  {:ttl 900
   :otp-digits 6
   :link-bytes 32})

(defn- digest-of [handle code]
  (encode/hex (digest/sha256 (string handle ":" code))))

(defn issue
  ``Create a challenge for `subject` and store its digest. Returns
  `{:handle :code :kind :expires}` — the code exists here and nowhere
  else, so whatever delivers it must be called with this value.

  `:kind` is :link (default) or :otp. For :otp the handle defaults to
  the subject, so asking for a second code replaces the first; for
  :link it is a fresh random id, which is what goes in the URL next
  to the code.

  **Issuance must be rate-limited by the caller.** Single-attempt
  redemption makes one issued OTP a one-in-a-million guess, but the
  loop "issue a code to the victim, guess once" restores the odds one
  issuance at a time — and for :otp the handle is the subject, which
  an attacker knows. A route that calls this (or `auth/challenge!`)
  needs `:void.security/rate` (or an equivalent limit) on it; the
  generators put one there, and a composition that removes it has
  removed the brute-force protection, not a convenience.``
  [store subject &opt opts]
  (default opts {})
  (def kind (get opts :kind :link))
  (def ttl (get opts :ttl (defaults :ttl)))
  (def now (get opts :now (os/time)))
  (def handle
    (or (opts :handle)
        (case kind
          :otp (string subject)
          (encode/hex (random/bytes 8)))))
  (def code
    (case kind
      :otp (random/digits (get opts :digits (defaults :otp-digits)))
      (random/token (get opts :bytes (defaults :link-bytes)))))
  ((store :put) handle
   {:digest (digest-of handle code)
    :subject subject
    :kind kind
    :claims (get opts :claims {})
    :created now
    # the deadline travels in the record as well as in the store's
    # ttl, so that redeem can refuse a stale record a store handed
    # back anyway — see redeem on why the check exists twice
    :expires (+ now ttl)}
   ttl)
  {:handle handle :code code :kind kind :expires (+ now ttl)})

(defn redeem
  ``Redeem a challenge. Returns an identity on success and nil on
  anything else — wrong code, expired, already used, never issued.

  The record is removed whichever way it goes: see the module
  docstring on why a challenge gets one attempt.

  Expiry is checked here, against the `:expires` the record carries,
  even though both shipped stores already refuse a stale record in
  `:take`: the store contract does not *require* that check, and a
  third-party store that forgets it would otherwise mint eternal
  magic links without anything saying so. Defense in depth — a record
  from before this field existed (no `:expires`) is let through.``
  [store handle code &opt opts]
  (default opts {})
  (def now (get opts :now (os/time)))
  (when (and handle code)
    (when-let [record ((store :take) (string handle))]
      (def expires (get record :expires))
      (when (and (or (nil? expires) (> expires now))
                 (ct/equal? (digest-of (string handle) (string code)) (record :digest)))
        (identity/make (record :subject)
                       {:via (case (record :kind) :otp :otp :magic-link)
                        :cookie false
                        :claims (get record :claims {})
                        :at now})))))
