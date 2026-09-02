# Background jobs and the dashboard

A job is work with one owner that must not happen on the request path.
The queue lives in your own database (`:jobs/db`) or in redis
(`:jobs/redis`) — same code either way — and the dashboard ships in
the box.

The snippets are from
[examples/blog/jobs.janet](../../examples/blog/jobs.janet), which
keeps a denormalized comment counter true; the deployed worker shape
is [examples/hub](../../examples/hub).

## Declare a job

```janet
(jobs/defjob recount-comments
  ``Bring one article's comment counter back in line with the
  comments table, then invalidate the cached index. :unique :args
  collapses a burst of comments on the same article into one run.``
  {:queue :maintenance :max-attempts 5 :unique :args}
  [article-id]
  (def n (recount! article-id))
  (cache/forget index-cache-key)
  n)
```

Retries with backoff and jitter, priorities, delays, uniqueness and a
dead-letter queue are all options on the declaration; failed runs keep
their error history on the job record.

## Enqueue from a handler

One line, inside the request that caused the work
([examples/blog/app.janet](../../examples/blog/app.janet)):

```janet
(jobs/enqueue :recount-comments (article :id))
```

With the db backend, enqueue participates in the surrounding
transaction — a rolled-back request enqueues nothing.

## Cron

`defschedule` fires once across a fleet, not once per process:

```janet
(jobs/defschedule nightly-recount
  "0 3 * * *"
  :recount-all)
```

## Run a worker

In dev, jobs run inside `void dev`. In production the worker is the
same binary/image with a different command — the process that enqueues
is not the process that delivers
([examples/hub/docker-compose.yml](../../examples/hub/docker-compose.yml)):

```yaml
worker:
  image: void-hub          # the same image as the web tier
  command: ["janet", "main.janet", "jobs", "work"]
```

`void jobs stats`, `void jobs list`, `void jobs retry` and friends
work against the same queue from the CLI — and therefore also as MCP
tools, since an agent's tools are the read-only CLI commands.

## The dashboard

Compose `:void/admin` and `:void/admin-jobs` and the queue gets a
Sidekiq-web-style section under `/admin/jobs`: backend capabilities,
backlog and dead counts, a queue × state depth table with clickable
numbers, per-job pages with the full failure history, retry/discard
one at a time or in bulk behind a server-side confirmation page. It is
built as a projection of the jobs contract — the proof that the
pattern works, and nothing about it is specific to jobs.

The gate is shut by construction: the admin refuses every request
until `[:admin :access]` names one of *your* policies
([examples/blog/admin.janet](../../examples/blog/admin.janet) is a
working example).
