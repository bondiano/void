### void/security/csp — a Content-Security-Policy built from data
### (ADR-0025 §3).
###
### A CSP is a string in the end, but writing it as one gives up
### everything: it cannot be validated, it cannot be merged by layer,
### and the typo that turns a policy off (`script-src` vs `scripts-src`
### — an unknown directive is *ignored*, not rejected) is invisible. So
### the configuration is a map of directive -> sources, the keywords
### are checked against the directives that exist, and the string is a
### projection:
###
###     {:default-src [:self]
###      :script-src [:self "https://cdn.example.com"]
###      :frame-ancestors [:none]}
###
###     default-src 'self'; script-src 'self' https://cdn.example.com;
###     frame-ancestors 'none'
###
### Keyword sources are the quoted ones (`:self` -> `'self'`), strings
### are hosts and schemes, and `:nonce` is replaced with this request's
### nonce — which the page must then put on its inline scripts
### (`(security/nonce)`), so it is opt-in rather than the default:
### a nonce directive with no nonce on the tags is a page whose scripts
### silently stop running.
###
### `report-only` is the switch that makes CSP adoptable at all: the
### same policy, reported instead of enforced, until the reports stop.

(def directives
  ``Directive -> whether it takes a source list. Anything not here is
  refused at boot: an unknown directive is silently ignored by
  browsers, which makes a typo indistinguishable from a policy.``
  {:default-src true :script-src true :style-src true :img-src true
   :font-src true :connect-src true :media-src true :object-src true
   :frame-src true :frame-ancestors true :form-action true :base-uri true
   :worker-src true :manifest-src true :child-src true :script-src-elem true
   :style-src-elem true :script-src-attr true :style-src-attr true
   :report-uri true :report-to true :sandbox true
   :upgrade-insecure-requests false :block-all-mixed-content false})

(def quoted-sources
  "Sources a browser expects in single quotes."
  {:self "'self'" :none "'none'" :unsafe-inline "'unsafe-inline'"
   :unsafe-eval "'unsafe-eval'" :strict-dynamic "'strict-dynamic'"
   :unsafe-hashes "'unsafe-hashes'" :wasm-unsafe-eval "'wasm-unsafe-eval'"
   :report-sample "'report-sample'"})

(def defaults
  ``The default policy: everything from this origin, no plugins, no
  framing, forms only to ourselves. It is deliberately not
  `:unsafe-inline` anywhere — a default that allows inline scripts is
  a default that does nothing.``
  {:default-src [:self]
   :base-uri [:self]
   :form-action [:self]
   :frame-ancestors [:none]
   :object-src [:none]
   :img-src [:self "data:"]})

(defn- source-str [source nonce]
  (cond
    (= :nonce source)
    (if nonce (string/format "'nonce-%s'" nonce) nil)

    (keyword? source)
    (or (quoted-sources source)
        # a keyword that is not a known quoted source is a host written
        # as a keyword by mistake — say so rather than emit 'typo'
        (errorf "CSP source %q is not a known keyword (%s); hosts and schemes are strings"
                source (string/join (map string (sorted (keys quoted-sources))) " ")))

    (bytes? source) (string source)

    (errorf "CSP source must be a keyword or a string, got %q" source)))

(defn validate
  "Check a policy map; throws on an unknown directive or source."
  [policy]
  (eachp [directive sources] policy
    (unless (in directives directive)
      (errorf "unknown CSP directive %q (known: %s)" directive
              (string/join (map string (sorted (keys directives))) " ")))
    (if (directives directive)
      (do
        (unless (indexed? sources)
          (errorf "CSP directive %q takes a list of sources, got %q" directive sources))
        (each s sources (source-str s "x")))
      (unless (boolean? sources)
        (errorf "CSP directive %q takes true or false, got %q" directive sources))))
  policy)

(defn render
  ``The header value for a policy, with `nonce` substituted for
  `:nonce` sources. Directives are emitted in a stable order so that
  two processes produce the same header — a diff between two machines
  should mean a different policy, not a different hash order.``
  [policy &opt nonce]
  (def parts
    (seq [directive :in (sorted (keys policy))
          :let [sources (get policy directive)]
          :when (if (directives directive) (not (empty? sources)) sources)]
      (if (directives directive)
        (string/join [(string directive)
                      ;(filter truthy? (map |(source-str $ nonce) sources))]
                     " ")
        (string directive))))
  (string/join parts "; "))

(defn needs-nonce?
  "Does this policy mention :nonce anywhere? Only then is one
  generated — a nonce nobody uses is 16 random bytes per request."
  [policy]
  (truthy?
    (some (fn [sources] (and (indexed? sources) (truthy? (index-of :nonce sources))))
          (values policy))))

(defn header-name
  "Which header carries the policy: enforcing, or reporting only."
  [report-only?]
  (if report-only?
    "content-security-policy-report-only"
    "content-security-policy"))
