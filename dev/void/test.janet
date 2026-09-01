### void/test — test support (SPEC.md §4).
###
### Fixtures are components: bring up just the subset of the system a
### test needs (:only — the listed components plus their transitive
### deps) and swap real components for stubs by re-registering the
### same :key (:components override). Factories come straight from the
### schema layer through the :generator projection — one declaration
### feeds validation, docs and test data alike (ADR-0008). `snapshot`
### stores golden renderings under test/snapshots (hiccup views).

(import spork/json)
(import void/core/system :as system)
(import void/core/plugin :as plugin)
(import void/core/hooks :as hooks)
(import void/core/deploy :as deploy)
(import ./dev/generate :as gen)

(def- allowed-opts
  {:plugins true :profile true :config true :only true :components true})

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

(defn- deps-closure [sys ks]
  (def needed @{})
  (defn visit [k]
    (unless (in needed k)
      (unless (get-in sys [:components k])
        (errorf "test/start!: unknown component %q in :only (components: %s)"
                k (names-str (keys (sys :components)))))
      (put needed k true)
      (each rk (values (get-in sys [:resolution k] {}))
        (visit rk))))
  (each k ks (visit k))
  needed)

(defn start!
  ``Bootstrap and start a test system.

  Options — plugin/bootstrap's :plugins/:profile/:config (the profile
  defaults to :test) plus:
    :components  extra component definitions; one with an existing
                 :key replaces the real component — the stub/fixture
                 mechanism
    :only        component keys to start; their transitive deps come
                 along, everything else is left out of the graph

  The bootstrap is untracked (it never becomes the REPL tools' default
  subject). Returns the boot value.``
  [opts]
  (eachk k opts
    (unless (in allowed-opts k)
      (errorf "test/start!: unknown option %q (allowed: %s)"
              k (names-str (keys allowed-opts)))))
  (def boot-opts
    (tabseq [k :in [:plugins :config] :when (get opts k)] k (opts k)))
  (put boot-opts :profile (get opts :profile :test))
  (def boot (plugin/bootstrap boot-opts true))
  (def sys (boot :system))
  (def comps (merge-into @{} (sys :components)))
  (each c (get opts :components [])
    (put comps (c :key) c))
  (def cfg (sys :config))
  (var sub (system/init comps cfg))
  (when-let [only (get opts :only)]
    (def needed (deps-closure sub only))
    (set sub (system/init (filter |(in needed ($ :key)) (values comps)) cfg)))
  (put boot :system sub)
  # the full lifecycle, like plugin/start! — :before-start is where
  # route tables and contexts build (ADR-0017: the inject path must be
  # the production wiring, not a shortcut)
  (hooks/run! (boot :hooks) :config-loaded boot)
  (hooks/run! (boot :hooks) :before-start boot)
  (system/start sub)
  (put boot :phase :ready)
  (hooks/run! (boot :hooks) :after-start boot)
  # and the store survey, for the same reason as everything above it:
  # a composition that would not start in production must not start
  # here either (ADR-0017, ADR-0030). Under the :test profile the
  # shape is :single and this is inert — a test that wants the gate
  # asks for it with [:deploy :shape] :fleet.
  (put boot :stores (deploy/check! boot))
  boot)

(defn stop!
  "Stop a test system (reverse order, per-component timeout in
  seconds, default 5); the :before-stop/:after-stop hooks run
  protected, like plugin/shutdown!. Returns the boot value."
  [boot &opt timeout]
  (default timeout 5)
  (each e (hooks/run-protected! (boot :hooks) :before-stop boot)
    (eprint e))
  (system/stop (boot :system) timeout)
  (put boot :phase :stopped)
  (each e (hooks/run-protected! (boot :hooks) :after-stop boot)
    (eprint e))
  boot)

(defmacro with-system
  ``Run body with a started test system, always stopping it:

      (test/with-system [boot {:plugins [my/plugin] :only [:db/pool]}]
        (def pool (system/instance (boot :system) :db/pool))
        ...)``
  [binding & body]
  (unless (and (indexed? binding) (= 2 (length binding)))
    (error "with-system expects [binding-symbol options] and a body"))
  (def [sym opts] binding)
  ~(do
     (def ,sym (,start! ,opts))
     (defer (,stop! ,sym)
       ,;body)))

(defn generate
  "Generate a sample value for a schema — see void/dev/generate."
  [sch &opt opts]
  (gen/generate sch opts))

(defn snapshot
  ``Compare the string rendering of `actual` against the stored
  snapshot `dir`/`name`.snap (dir defaults to "test/snapshots",
  relative to the package root jpm test runs from — hiccup snapshot
  testing, but any stringable value works).

  A missing snapshot is created and the call succeeds — review and
  commit it. On a mismatch the call throws with both versions; run
  with VOID_SNAPSHOT_UPDATE=1 to rewrite the stored snapshots
  instead. Returns :created, :updated or :matched.``
  [name actual &opt dir]
  (default dir "test/snapshots")
  (def path (string dir "/" name ".snap"))
  (def s (string actual))
  (defn write! []
    (var acc "")
    (each part (string/split "/" dir)
      (set acc (if (empty? acc) part (string acc "/" part)))
      (unless (or (empty? acc) (= "." acc))
        (os/mkdir acc)))
    (spit path s))
  (cond
    (nil? (os/stat path))
    (do (write!) :created)

    (= (string (slurp path)) s)
    :matched

    (os/getenv "VOID_SNAPSHOT_UPDATE")
    (do (write!) :updated)

    (errorf "snapshot %q differs from %s:\n--- stored ---\n%s\n--- actual ---\n%s\n(run with VOID_SNAPSHOT_UPDATE=1 to update)"
            name path (slurp path) s)))

(defn factory
  ``A sample value for a map schema with explicit overrides on top:

      (test/factory User :email "fixed@example.com")

  Returns a mutable table. Overrides are the escape hatch for fields
  the generator cannot invent (:pred, :pattern ...).``
  [sch & kvs]
  (when (odd? (length kvs))
    (error "factory: expected key-value override pairs"))
  (def base (generate sch))
  (if (empty? kvs)
    base
    (do
      (unless (dictionary? base)
        (errorf "factory overrides need a map schema, generated %q" base))
      (merge-into (if (table? base) base (merge-into @{} base))
                  (table ;kvs)))))

# -- the inject client (ADR-0017) ----------------------------------------
#
# Fastify-style app.inject: drive the full HTTP stack in memory —
# routing, lifecycle stages, middleware, rendering, wire serialization
# — with zero sockets. void/test talks to the :http/kernel component
# instance through its duck-typed surface (:handler :make-request
# :serialize :notify-response), so void/dev (wave 0) never imports
# void/http (wave 1). The client keeps a cookie jar and base headers;
# request sugar (:json/:form/:raw) is the kernel's make-request.

(defn- kernel-of [boot]
  (or (get-in boot [:system :instances :http/kernel])
      (error "test/client: the :http/kernel component is not running — include :void/http in :plugins (test/with-http starts :only [:http/kernel])")))

(defn client
  ``An inject client over a started boot (see with-http):
  {:boot :kernel :cookies <jar> :headers <base headers>}. Responses'
  set-cookie headers land in the jar and ride along on subsequent
  requests — session flows (login -> authorized request) need no
  manual cookie threading.``
  [boot &opt opts]
  @{:boot boot
    :kernel (kernel-of boot)
    :cookies @{}
    :headers (merge @{} (get opts :headers @{}))})

(defn- jar-update! [jar resp]
  (def sc (get-in resp [:headers "set-cookie"]))
  (each one (cond (nil? sc) [] (indexed? sc) sc [sc])
    (def pair (first (string/split ";" (string one))))
    (when-let [eq (string/find "=" pair)]
      (def name (string/trim (string/slice pair 0 eq)))
      (def value (string/trim (string/slice pair (inc eq))))
      # an emptied value is a deletion
      (if (empty? value)
        (put jar name nil)
        (put jar name value)))))

(defn- jar-header [jar]
  (unless (empty? jar)
    (string/join (seq [k :in (sorted (keys jar))]
                   (string k "=" (jar k)))
                 "; ")))

(defn inject
  ``One in-memory request through the whole stack (ADR-0017):

      (test/inject c {:uri "/orders"})
      (test/inject c {:method :post :uri "/login"
                      :form {:email "a@b.c" :password "pw"}})
      (test/inject c {:uri "/api" :json {:title "x"}})
      (test/inject c {:raw "GET / HTTP/1.1\r\n..."})

  The request runs the same chain a socket request would — lifecycle
  stages included — and the response is then serialized by the same
  wire code the server uses: the result is the response table plus
  :raw (the exact bytes that would hit the socket). :on-response fires
  after serialization, exactly like the server path.``
  [c spec]
  (def kernel (c :kernel))
  (def req ((kernel :make-request) spec))
  # base headers + cookie jar (explicit headers win)
  (eachp [k v] (c :headers)
    (when (nil? (get (req :headers) k))
      (put (req :headers) k v)))
  (when-let [cookie (jar-header (c :cookies))]
    (when (nil? (get (req :headers) "cookie"))
      (put (req :headers) "cookie" cookie)))
  (def resp
    (let [r ((kernel :handler) req)]
      # a handler may answer with an immutable struct — :raw needs a table
      (if (table? r) r (merge-into @{} r))))
  (def raw ((kernel :serialize) req resp))
  (put resp :raw (string raw))
  (jar-update! (c :cookies) resp)
  ((kernel :notify-response) req resp)
  resp)

(defn text
  "The response body as a string."
  [resp]
  (string (or (resp :body) "")))

(defn json
  "Decode a JSON response body (keyword keys)."
  [resp]
  (json/decode (text resp) true))

(defn sse-events
  ``Parse the SSE frames out of an injected response's :raw bytes:
  [{:event "..." :data "..." :id "..."} ...] — :data joins multi-line
  data fields with newlines.``
  [resp]
  (def raw (or (resp :raw) (error "sse-events needs an injected response (:raw)")))
  (def start (or (string/find "\r\n\r\n" raw) -4))
  (def body (string/slice raw (+ 4 start)))
  # chunked framing: strip "<hex>\r\n" ... "\r\n" chunk envelopes
  (def payload
    (if (string/find "transfer-encoding: chunked" (string/ascii-lower (string/slice raw 0 (+ 4 start))))
      (do
        (def out @"")
        (var i 0)
        (while (< i (length body))
          (def line-end (or (string/find "\r\n" body i) (length body)))
          (def size (scan-number (string "0x" (string/slice body i line-end))))
          (when (or (nil? size) (zero? size)) (break))
          (buffer/push out (string/slice body (+ 2 line-end) (+ 2 line-end size)))
          (set i (+ 2 line-end size 2)))
        (string out))
      body))
  (def events @[])
  (each block (string/split "\n\n" (string/replace-all "\r\n" "\n" payload))
    (def ev @{})
    (def data @[])
    (each line (string/split "\n" block)
      (cond
        (string/has-prefix? "data:" line)
        (array/push data (string/trim (string/slice line 5)))
        (string/has-prefix? "event:" line)
        (put ev :event (string/trim (string/slice line 6)))
        (string/has-prefix? "id:" line)
        (put ev :id (string/trim (string/slice line 3)))))
    (unless (empty? data)
      (put ev :data (string/join data "\n"))
      (array/push events ev)))
  events)

(defmacro with-http
  ``Start the app kernel-only (no port), hand the body an inject
  client, stop in defer (ADR-0017):

      (test/with-http [c {:plugins [:void/http my-app/plugin]}]
        (def resp (test/inject c {:uri "/"}))
        (assert (= 200 (resp :status))))

  Options are test/start!'s; :only defaults to [:http/kernel].``
  [binding & body]
  (unless (and (indexed? binding) (= 2 (length binding)))
    (error "with-http expects [client-symbol options] and a body"))
  (def [sym opts] binding)
  ~(do
     (def boot (,start! (merge {:only [:http/kernel]} ,opts)))
     (def ,sym (,client boot))
     (defer (,stop! boot)
       ,;body)))
