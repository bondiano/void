# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Use GitHub's private vulnerability reporting on this repository
  (Security → Report a vulnerability), or
- email batbondik0@gmail.com with `[void security]` in the subject.

Include what you can: the affected package (`void/http`, `void/auth`, …),
a minimal reproduction, and the impact as you understand it. A report that
names the class of problem is enough — a working exploit is not required.

You will get an acknowledgement within a few days. Fixes ship as ordinary
releases; the report is credited in the changelog unless you ask otherwise.

## Scope

Everything in this repository: the framework packages, the CLI, the
generators, and the published examples. The deployment story assumes
inbound TLS terminates at a reverse proxy — reports about running the
bare server on the public internet without one are out of scope.

## Supported versions

Pre-1.0: only the latest tagged release is supported.
