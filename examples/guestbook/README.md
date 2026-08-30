# guestbook
A [void](https://github.com/bondiano/void) application — a
server-rendered HTMX guestbook with schema-validated forms.

    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void repl           # repl into the running process
    void plugins lock   # write void.lock; `void plugins check` in CI

Edit app.janet while `void dev` runs: handler changes are live
(late binding), new routes and metadata edits rebuild the route
table automatically.

`main.janet` is the entrypoint `void new` writes, and it is the shape a
deployable application has: the profile is read inside `main` rather
than into a value, the production composition is this one without
`void/dev`, and `cli/app-main` makes the process the `void` binary when
it is given arguments — so the single file `jpm build` produces can run
its own `db migrate` on a target with no janet
([docs/DEPLOY.md](../../docs/DEPLOY.md)).