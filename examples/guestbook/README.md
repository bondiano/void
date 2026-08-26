# guestbook
A [void](https://github.com/bondiano/void) application — a
server-rendered HTMX guestbook with schema-validated forms.

    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void repl           # repl into the running process

Edit app.janet while `void dev` runs: handler changes are live
(late binding), new routes and metadata edits rebuild the route
table automatically.