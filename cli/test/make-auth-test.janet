### `void make auth` — the scaffold, and the suite it generates
###.
###
### The examples are not rewritten to prove this command works: the
### scaffold is checked by what it itself generates. So this file runs the
### generator into a throwaway project and then runs the generated suite —
### which boots the generated plugin on a real sqlite database and drives
### register, sign in, sign out, reset and verify through test/inject. If
### the templates and the machinery under them ever drift apart, they
### drift apart here.

(import ../test-support/paths)
(import void/cli/make :as make)
(import void/cli/prompt :as prompt)

# work in a throwaway directory; jpm test runs with cwd = cli/
(def root (os/cwd))
(def sandbox (string root "/.tmp-make-auth-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defn- parses? [path]
  (def p (parser/new))
  (parser/consume p (slurp path))
  (parser/eof p)
  (not= :error (parser/status p)))

# -- the spec ------------------------------------------------------------

(def spec (make/auth-spec nil [] {:project "demo" :version "20260101000000"}))
(assert (= "user" (spec :name)) "an account is a user unless it is called something else")
(assert (= "User" (spec :entity)) "the entity binding")
(assert (= "users" (spec :table)) "the table void/auth-db is pointed at")
(assert (= "demo/auth" (spec :plugin))
        "one plugin per application, whatever the accounts are called")
(assert (= "auth" (spec :module-path))
        "the module lands beside app.janet, which is where void new put that one")

(def named (make/auth-spec "TeamMember" [] {:project "demo"}))
(assert (= "team-member" (named :name)) "the subject kind, kebab-spelled")
(assert (= "TeamMember" (named :entity)))
(assert (= "team_members" (named :table)))

(assert (not (first (protect (make/auth-spec "Bad_Name!" []))))
        "a name that cannot be a table is refused once, by name")
(assert (not (first (protect (make/auth-spec "user" [(make/parse-field "email")]))))
        "and so is a field the scaffold already declares")

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)
  (spit "project.janet" "(declare-project\n  :name \"demo\"\n  :version \"0.1.0\")\n")

  # -- the files ---------------------------------------------------------

  (def said @"")
  (def written
    (with-dyns [:out said prompt/interactive-dyn false]
      (make/auth "user" "name:string" "--version" "20260101000000")))
  (assert (deep= ["auth.janet"
                  "db/migrations/20260101000000_create_users.janet"
                  "test/auth-test.janet"]
                 (tuple ;(map string written)))
          "one file per template entry, where the spec says")
  (each f written (assert (parses? f) (string f " parses")))

  # nothing existing is edited: the composition and the config slice are
  # printed, because main.janet and config/dev.janet are files somebody
  # has already written in
  (each line [":demo/auth" ":void/auth :void/auth-http :void/auth-db"
              ":void/auth-user-store {:impl :auth.db/users}"
              ":auth-http {:unauthenticated :redirect :login-path \"/login\"}"
              ":mail-auth {:link-path \"/auth/link\"}"]
    (assert (string/find line (string said))
            (string "the next steps name " line)))
  (assert (string/find "a challenge nobody delivered is an error" (string said))
          "and say what happens without a deliverer, which is the one way to compose this wrong")

  # Everything the scaffold made necessary in a file it will not touch,
  # said here rather than left to be found: the driver's own
  # dependency, and the policy line that the :void/security it just put in
  # the composition needs for the htmx `void new` writes.
  (assert (string/find "github.com/janet-lang/sqlite3" (string said))
          "the suite it generated boots a driver whose library the bundle does not carry — so it names it")
  (assert (string/find "project.janet" (string said))
          "...and the file that line goes in")
  (assert (string/find ":script-src [:self \"https://unpkg.com\"]" (string said))
          "void/security's default policy refuses the scaffold's own htmx, so the generator prints the policy")
  (assert (string/find "never rewrites a file you have edited" (string said))
          "and says why none of this was done for you, since that is a decision and not an omission")

  # printed text nobody parses is text that drifts into being wrong. The
  # config block is meant to be pasted into a Janet file, so it is
  # parsed here, from the report, exactly as printed
  (def report (string/join (make/auth-report
                             (make/auth-spec "user" [] {:project "demo"}))
                           "\n"))
  (def block-start (string/find "{:http {:session" report))
  (def config-block
    (string/replace-all "\n       " "\n"
                        (string/slice report block-start
                                      (inc (last (string/find-all "}" report))))))
  (def [parsed-ok parsed] (protect (parse config-block)))
  (assert parsed-ok (string "the config block a person is told to paste is Janet: " parsed))
  (assert (index-of "https://unpkg.com" (get-in parsed [:security :csp :policy :script-src]))
          "...and the policy in it admits the host the generated page loads its script from")
  (assert (= "users" (get-in parsed [:auth-db :users :table]))
          "...and names this scaffold's own table, not a template's")

  (def module (slurp "auth.janet"))
  (assert (string/find "(db/defentity User" module) "the users table is an entity")
  (assert (string/find ":db/table \"users\"" module) "with the table void/auth-db reads")
  (assert (string/find "(schema/select User [:email :name])" module)
          "the sign-up form is a projection of the entity, plus the extra field")
  (assert (string/find "{:password [:string {:min 8 :max 200}]}" module)
          "and the one field that is not a column")
  (assert (string/find "(auth/hash-password" module)
          "the plaintext lives for one request; a PHC string is what is stored")
  (assert (string/find "auth-http/login!" module) "the session id rotates on a login")
  (assert (string/find ":claims {:purpose \"verify\"}" module)
          "what the two challenges are told apart by")
  (assert (string/find ":claims {:purpose \"reset\"}" module))
  (assert (= 1 (length (string/find-all "(auth/redeem!" module)))
          "one redeem route, because a deliverer builds one URL")
  (assert (string/find ":void.auth/access :required" module)
          "and the routes that need somebody say so rather than leaning on the default")
  (assert (= 3 (length (string/find-all ":void.security/csrf true" module)))
          "the three anonymous POSTs (login, register, the reset request) ask for the CSRF check by name — they carry no session cookie, which is exactly the login-CSRF hole")

  (def migration (slurp "db/migrations/20260101000000_create_users.janet"))
  (assert (string/find ":create-table \"users\"" migration))
  (assert (string/find "[:email :text {:null false :unique true}]" migration))
  (assert (string/find "[:name :text {:null false}]" migration)
          "an extra field is an extra column")
  (assert (string/find "(auth-db/tables)" migration)
          "the two tables void owns come as data, not as a migration of void's")

  # -- nothing is clobbered ----------------------------------------------

  (assert (not (first (protect
                        (with-dyns [prompt/interactive-dyn false]
                          (make/auth "user")))))
          "an existing file is not overwritten")

  # -- --dry-run writes nothing ------------------------------------------

  (def out @"")
  (def planned
    (with-dyns [:out out prompt/interactive-dyn false]
      (make/auth "operator" "--dir" "accounts" "--test-dir" "test/ops" "--dry-run")))
  (assert (not (os/stat "accounts/auth.janet")) "--dry-run writes no file")
  (assert (string/find "(db/defentity Operator" (string out))
          "and prints what it would have written")
  (assert (= 3 (length planned)) "for every entry of the template")
  (assert (= "accounts/auth.janet" (string (first planned)))
          "--dir moves the module")
  (assert (string/find "(import ../accounts/auth :as accounts)" (string out))
          "and the generated suite's import moves with it")

  # -- the project's own template wins -----------------------------------

  (os/mkdir "templates")
  (os/mkdir "templates/auth")
  (spit "templates/auth/migration.janet"
        "(defn render [spec] (string \"# \" (spec :table) \" by hand\\n\"))\n")
  (with-dyns [:out @"" prompt/interactive-dyn false]
    (make/auth "operator" "--dir" "accounts" "--test-dir" "test/ops"
               "--version" "20260101000100"))
  (assert (= "# operators by hand\n"
             (string (slurp "db/migrations/20260101000100_create_operators.janet")))
          "a project override replaces the built-in template")
  (assert (string/find "(db/defentity Operator" (slurp "accounts/auth.janet"))
          "and only the entry it overrides")

  (spit "templates/auth/migration.janet" "(def render 42)\n")
  (assert (not (first (protect (make/auth-templates))))
          "an override that is not a render function says so")

  # that experiment leaves the tree with a second scaffold in it; the
  # suite below is the first one's, and nothing should be loading a
  # module the assertions do not name
  (rimraf "templates")
  (rimraf "accounts")
  (rimraf "test/ops")
  (os/rm "db/migrations/20260101000100_create_operators.janet")

  # -- the generated suite runs ------------------------------------------
  #
  # The whole point of generating a suite: it passes against the code
  # that was generated with it. This one boots the plugin on sqlite and
  # drives every flow the scaffold ships — register, verify, sign out,
  # sign in, CSRF, the redirect a protected route makes, and the reset.

  (def [suite-ok suite-err] (protect (dofile "test/auth-test.janet")))
  (assert suite-ok
          (string "the generated suite passes against the generated scaffold: "
                  (if (string? suite-err) suite-err (describe suite-err)))))

(print "make-auth-test ok")
