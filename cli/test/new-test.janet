(import ../test-support/paths)
(import void/cli/new :as new)
(import void/cli :as cli)
(import void/core/plugin :as plugin)
(import void/http :as http)

# work in a throwaway directory; jpm test runs with cwd = cli/
(def root (os/cwd))
(def sandbox (string root "/.tmp-new-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)

  # -- validation --------------------------------------------------------
  (assert (not (first (protect (new/create)))) "no name -> usage error")
  (assert (not (first (protect (new/create "Bad_Name"))))
          "invalid name is rejected")

  # -- the skeleton is written -------------------------------------------
  (def files (new/create "sample"))
  (each f ["project.janet" "main.janet" "app.janet"
           "config/dev.janet" "config/prod.janet"
           "docker-compose.dev.yml" "test/smoke-test.janet"
           ".gitignore" "README.md"]
    (assert (os/stat (string "sample/" f)) (string f " exists")))
  (assert (not (first (protect (new/create "sample"))))
          "an existing directory is refused")

  # the dev compose is infrastructure only — postgres, redis, mailpit —
  # and never the application as an image: that is the prod form, and it
  # lives in the examples
  (def compose (slurp "sample/docker-compose.dev.yml"))
  (each svc ["postgres" "redis" "mailpit" "healthcheck"]
    (assert (string/find svc compose) (string "compose runs " svc)))
  (assert (not (string/find "build:" compose))
          "no application image in the dev compose")
  (assert (string/find "54321:5432" compose)
          "dev ports are non-standard, so a system postgres keeps its own")

  # config/prod.janet is the layer the config chain will eval — it has
  # to come back as a dictionary, not just parse
  (def [prod-ok prod] (protect (eval-string (slurp "sample/config/prod.janet"))))
  (assert prod-ok "config/prod.janet evaluates")
  (assert (= 8080 (get-in prod [:http :port])) "and answers on a port")
  (assert (= "0.0.0.0" (get-in prod [:http :host]))
          "a :prod server answers the network, not loopback")

  # every generated janet file parses
  (each f files
    (when (string/has-suffix? ".janet" f)
      (def p (parser/new))
      (parser/consume p (slurp f))
      (parser/eof p)
      (assert (not= :error (parser/status p)) (string f " parses"))))

  # the generated project declares a real dependency, not a comment: the
  # Quick start is an executable claim, and this is the unit-level half of
  # the CI step that installs the bundle for real
  (def manifest (slurp "sample/project.janet"))
  (assert (string/find "https://github.com/bondiano/void.git" manifest)
          "project.janet depends on the void bundle")

  # -- the generated project bootstraps ----------------------------------
  # load it the way the void binary would: project root on module/paths,
  # require main, read the app binding, bootstrap + build the route table
  (os/cd "sample")
  (cli/add-project-paths! (os/cwd))
  (def app (cli/load-app))
  (assert (deep= (freeze (cli/resolve-plugins app :dev))
                 [:void/http :void/html :void/htmx :void/dev :sample/app])
          "main.janet's :plugins-for answers the full wave-1 list in :dev")
  (assert (deep= (freeze (cli/resolve-plugins app :prod))
                 [:void/http :void/html :void/htmx :sample/app])
          "and drops :void/dev in :prod — one composition per profile")

  (def boot (cli/bootstrap-app app :dev))
  (assert (= :validated (boot :phase)) "bootstrap passes, nothing started")
  (def table (http/routes-table))
  (assert (get-in table [:by-name :home]) "the / route lands in the table")
  (assert (get-in table [:by-name :entries/create])
          "the POST /entries route lands in the table")
  (assert (empty? (filter |(= :running $) (values (get-in boot [:system :states]))))
          "bootstrap-app starts no components")

  # the config file layer is picked up (config/dev.janet sets the port)
  (assert (= 8080 (get-in boot [:config :values :http :port]))
          "config/dev.janet is loaded")

  # -- the generated app serves the guestbook loop without a socket ------
  (def page (http/with-request {:uri "/"}))
  (assert (= 200 (page :status)) "GET / renders")
  (assert (string/find "<form" (string (page :body))) "the schema form renders")
  (assert (string/find "htmx.org" (string (page :body))) "htmx is on the page")

  (def bad (http/with-request
             {:method :post :uri "/entries"
              :headers {"content-type" "application/x-www-form-urlencoded"}
              :body "name=&message="}))
  (assert (string/find "field-errors" (string (bad :body)))
          "an invalid submission re-renders with schema errors")

  # what htmx 4 sends when the swap lands in #guestbook rather than in
  # the body: HX-Request-Type is what :void.htmx/partial reads
  (def good (http/with-request
              {:method :post :uri "/entries"
               :headers {"content-type" "application/x-www-form-urlencoded"
                         "hx-request" "true"
                         "hx-request-type" "partial"
                         "hx-target" "div#guestbook"}
               :body "name=ada&message=hello"}))
  (assert (string/find "ada" (string (good :body))) "a valid entry is listed")
  (assert (not (string/find "<html" (string (good :body))))
          ":void.htmx/partial strips the layout for the htmx POST")

  # -- void routes works against the generated app -----------------------
  (def out @"")
  (with-dyns [:out out]
    (def commands (plugin/extension boot :void.core/cli))
    (def [command args] (cli/find-command commands ["routes"]))
    (cli/run-command boot command args))
  (assert (string/find "GET" (string out)) "void routes prints the method")
  (assert (string/find "/" (string out)) "void routes prints the pattern")
  (assert (string/find ":home" (string out)) "void routes prints the name")

  # -- the generated smoke suite runs ------------------------------------
  #
  # The point of shipping a test/ directory: it is green before the
  # first line is edited. The suite boots the generated composition
  # through test/with-http and drives the guestbook loop with
  # test/inject — same as `jpm --local test` will in the new project.
  (def [smoke-ok smoke-err] (protect (dofile "test/smoke-test.janet")))
  (assert smoke-ok
          (string "the generated smoke suite passes against the generated app: "
                  (if (string? smoke-err) smoke-err (describe smoke-err)))))

(print "new-test ok")
