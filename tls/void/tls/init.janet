### void/tls — outbound TLS from the system libssl through ffi
### (SPEC §1 п. 4, ROADMAP wave 5, ADR-0038).
###
### The plugin closes the bookmark ADR-0010 left open — "an ffi plugin
### void/tls is possible later" — for the half where the reverse-proxy
### answer scales badly: *outbound* connections. Composing it makes
### `https://` a working scheme in `void/http/client`, `rediss://` a
### working scheme in `void/redis`, and STARTTLS/`:smtps` working
### modes in `void/mail`; `void/oauth` and `void/obs-otlp` start
### accepting https endpoints at their gates. Inbound TLS stays at the
### proxy: ADR-0010 is not revisited.
###
### The integration is a seam, not an edge (ADR-0038 §4): each
### consumer holds a `(var tls-... nil)` and keeps its old
### relay-naming error while it is nil; `install!` here puts this
### package's connector into every seam, and the plugin does that on
### load. Wave-1 packages therefore never import wave-5 code, and a
### composition without :void/tls is byte-for-byte what it was.
###
### The library opens at :start (like libcrypto, like libpq): a
### missing libssl is a boot error naming every path tried, never an
### explosion on import. BIO and the X509 error strings come off
### void/crypto's open libcrypto — one crypto stack in the process.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./lib :as lib)
(import ./stream :as stream)
# the consumer seams (ADR-0038 §4). Importing them is legal — wave 5
# may depend on any earlier wave — and costs nothing at runtime: each
# import is the module the composition was going to load anyway.
(import void/http/client :as http-client)
(import void/redis/conn :as redis-conn)
(import void/mail/smtp :as smtp)

(def log-ns "void.tls")

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:tls] config slice."
  {:libssl [:optional :string]
   :verify [:optional :boolean]
   :ca-file [:optional :string]
   :ca-path [:optional :string]
   :min-version [:optional :keyword]})

(def defaults
  ``Defaults of the [:tls] slice.

  `:verify` true — and false in the :prod profile is a boot error, not
  a setting: going to the network without checking who answered is a
  decision a deployment makes out loud (the stance void/mail takes on
  plaintext AUTH). `:ca-file`/`:ca-path` unset means the library's own
  trust anchors (`void tls info` shows what those are).``
  {:libssl nil
   :verify true
   :ca-file nil
   :ca-path nil
   :min-version :tls1.2})

# -- public surface (re-exports) -----------------------------------------

(def load! "See lib/load! — open libssl and install the bindings." lib/load!)
(def available? "See lib/available? — is a library open?" lib/available?)
(def candidates "See lib/candidates — where the library is looked for." lib/candidates)
(def version "See lib/version — [major minor patch] of the open libssl." lib/version)
(def context "See stream/context — build a shareable SSL_CTX." stream/context)
(def close-context "See stream/close-context." stream/close-context)
(def wrap "See stream/wrap — a TLS session over an open stream." stream/wrap)
(def connect "See stream/connect — net/connect plus wrap." stream/connect)
(def tls-version "See stream/tls-version — the negotiated protocol." stream/tls-version)

# -- the seams (ADR-0038 §4) ---------------------------------------------

(defn install!
  ``Put this package's connector into every consumer seam:
  `void/http/client` and `void/redis` get `connect`, `void/mail` gets
  `wrap` (STARTTLS upgrades a socket that has already spoken). The
  plugin calls this on load; a test or a one-shot script that skips
  the plugin calls it directly, after `(tls/load!)`.``
  []
  (set http-client/tls-connect stream/connect)
  (set redis-conn/tls-connect stream/connect)
  (set smtp/tls-wrap stream/wrap)
  nil)

# -- the component -------------------------------------------------------

(defn- slice [cfg]
  (merge defaults (or cfg {})))

(def lib-component
  (system/component :tls/lib
    :doc "The open libssl and the shared client SSL_CTX built from
    [:tls]: trust anchors, minimum protocol version, verification.
    Every consumer seam's connection goes through that context."
    :provides [:void/tls]
    :config {:key :tls :schema Config}
    :start
    (fn start [_ cfg0]
      (install!) # idempotent; :on-load already did it on the boot path,
                 # a REPL component restart comes through here alone
      (def cfg (slice cfg0))
      (def path (lib/load! (cfg :libssl)))
      (def ctx (stream/context {:verify (cfg :verify)
                                :ca-file (cfg :ca-file)
                                :ca-path (cfg :ca-path)
                                :min-version (cfg :min-version)}))
      # replace the lazy default: from here every seam connection uses
      # the configured trust anchors
      (set stream/default-ctx ctx)
      (log/info "libssl ready" :ns log-ns
                :path path
                :verify (cfg :verify)
                :ca (or (cfg :ca-file) (cfg :ca-path) :library-default)
                :min-version (cfg :min-version))
      {:path path
       :version (lib/version)
       :ctx ctx
       :verify (cfg :verify)
       :ca-file (cfg :ca-file)
       :ca-path (cfg :ca-path)
       :min-version (cfg :min-version)})
    :stop
    (fn stop [inst]
      # SSL_CTX is reference-counted: sessions still open keep it
      # alive, this only drops the component's reference
      (when (= stream/default-ctx (inst :ctx))
        (set stream/default-ctx nil))
      (stream/close-context (inst :ctx))
      nil)
    :health
    (fn health [inst]
      {:status :up
       :library (inst :path)
       :verify (inst :verify)
       :min-version (inst :min-version)})))

# -- gates ---------------------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :tls/verify-gate
   :doc "Refuse [:tls :verify] false in the :prod profile"
   :fn (fn verify-gate [boot]
         (when (and (= :prod (get boot :profile :dev))
                    (false? (get-in boot [:config :values :tls :verify])))
           (error (string "[:tls :verify] is false in the :prod profile — production "
                          "talks to the network without checking certificates only by "
                          "explicit decision, and this switch is not it. Point "
                          "[:tls :ca-file] at the CA that signed your internal "
                          "certificates instead"))))})

# -- interface, CLI ------------------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/tls
   :doc "Outbound TLS: which libssl is open and the shared client context built from [:tls]. Consumers reach it through their seams (https:// in the http client, rediss:// in redis, :starttls/:smtps in mail), not through this key."
   :methods {:path "the library this process opened"
             :version "[major minor patch]"
             :ctx "the shared client SSL_CTX"}})

(defn print-info
  "Print what this process's libssl does — the body of `void tls info`."
  [inst]
  (printf "library      %s" (inst :path))
  (printf "version      %s" (string/join (map string (or (inst :version) [])) "."))
  (printf "verify       %s" (if (inst :verify) "on" "OFF — every certificate is trusted"))
  (printf "trust        %s" (or (inst :ca-file) (inst :ca-path)
                                "the library's default paths"))
  (printf "min version  %s" (string (inst :min-version))))

(plugin/contribute! :void.core/cli
  {:name :tls/info
   :read-only? true
   :doc "Show which libssl is open and how it verifies peers: void tls info"
   :needs [:tls/lib]
   :fn (fn cli-info [inst & args]
         (unless (empty? args)
           (errorf "void tls info takes no arguments (got %q)"
                   (string/join args " ")))
         (print-info inst))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/tls
  :doc "Outbound TLS through the system libssl: https:// in the http client, rediss:// in redis, STARTTLS and smtps in mail, https endpoints at the oauth and OTLP gates. Memory-BIO pump on the ev loop — no thread, no native module — with verification and SNI on by construction; the library opens at :start. Inbound TLS stays at the reverse proxy (ADR-0010)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/crypto ">=0.0.1"}
  :config-key :tls
  :config-schema Config
  :config-defaults defaults
  :components [lib-component]
  :on-load (fn on-load [_] (install!)))
