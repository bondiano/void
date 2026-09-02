# Cookbook

Short recipes, each distilled from a working example in this
repository — every snippet is lifted from code a CI job runs, and each
page links to the full source it came from. If a recipe and the
example disagree, the example is right.

- [Forms → validation → htmx](forms.md) — one schema driving the
  markup, the coercing validation and the re-render-with-errors loop.
  From the `void new` scaffold and [examples/blog](../../examples/blog).
- [Background jobs and the dashboard](jobs.md) — `defjob`, retries,
  uniqueness, cron, a separate worker process and the built-in
  dashboard. From [examples/blog](../../examples/blog) and
  [examples/hub](../../examples/hub).
- [Auth: passwords, magic links, API tokens](auth.md) — the
  `void make auth` scaffold, and the three sign-in shapes on top of
  `void/auth`. From [examples/blog](../../examples/blog) and
  [examples/shop](../../examples/shop).
- [Deploy: one binary, or compose](deploy.md) — `jpm --local build`,
  the binary that is also the CLI, and the fleet shape with
  `docker compose`. From [DEPLOY.md](../DEPLOY.md) and
  [examples/hub](../../examples/hub).

New here? Start with [Getting started](../GETTING-STARTED.md) — the
cookbook assumes a project exists.
