# hub

A [void](https://github.com/bondiano/void) application — a
server-rendered HTMX guestbook with schema-validated forms.

    jpm --local deps    # pin void in ./jpm_tree (once, and after a bump)
    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void repl           # repl into the running process

Scaffold a CRUD resource — entity, form, views, routes, migration and
a suite, every one of them a projection of one declaration:

    void make resource Product name:string price:int notes:text?

Scaffold the pages every application writes by hand — register, sign
in, sign out, a password reset and an address to verify — on top of
void/auth, with a suite that drives all of them:

    void make auth

Lock the composition, so that "why is the middleware stack different in
production" is a diff rather than an investigation:

    void plugins lock   # writes void.lock — commit it
    void plugins check  # in CI

Ship it as one file, with no janet and no source tree on the target
(docs/DEPLOY.md in the void repository):

    jpm --local build
    VOID_PROFILE=prod VOID_HTTP__PORT=8080 ./build/hub

Edit app.janet while `void dev` runs: handler changes are live (late
binding), and new routes or metadata edits rebuild the route table
automatically.
