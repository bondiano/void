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
           "config/dev.janet" ".gitignore" "README.md"]
    (assert (os/stat (string "sample/" f)) (string f " exists")))
  (assert (not (first (protect (new/create "sample"))))
          "an existing directory is refused")

  # every generated janet file parses
  (each f files
    (when (string/has-suffix? ".janet" f)
      (def p (parser/new))
      (parser/consume p (slurp f))
      (parser/eof p)
      (assert (not= :error (parser/status p)) (string f " parses"))))

  # -- the generated project bootstraps ----------------------------------
  # load it the way the void binary would: project root on module/paths,
  # require main, read the app binding, bootstrap + build the route table
  (os/cd "sample")
  (cli/add-project-paths! (os/cwd))
  (def app (cli/load-app))
  (assert (deep= (app :plugins)
                 [:void/http :void/html :void/htmx :void/dev :sample/app])
          "main.janet declares the full wave-1 plugin list")

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

  (def good (http/with-request
              {:method :post :uri "/entries"
               :headers {"content-type" "application/x-www-form-urlencoded"
                         "hx-request" "true"}
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
  (assert (string/find ":home" (string out)) "void routes prints the name"))

(print "new-test ok")
