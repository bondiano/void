### void shop — the image.
###
### Build context is the **repository root**, because the framework is
### installed from this checkout rather than from a release:
###
###     docker build -f examples/shop/Dockerfile -t void-shop ../..
###
### (docker-compose.yml does that for you.) An application outside this
### repository replaces the two `jpm` lines below with one dependency
### in its own project.janet — `https://github.com/bondiano/void.git`,
### the whole framework as one bundle (ADR-0020).
###
### Two stages, and the split is the point: everything that needs a
### compiler happens in the first — janet itself, jpm, spork's nine
### native modules, janet-lang/sqlite3 and void/fdwait's ~60 lines of C
### — and the second carries a janet runtime, the installed tree, two
### shared libraries and the application. void's target is "a single
### binary under 5 MB and an RSS under 50 MB" (SPEC §8), and the image
### it ships in should not be 900 MB of build tools.

# ---------------------------------------------------------------- build
FROM debian:bookworm-slim AS build

ARG JANET_VERSION=v1.41.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# janet, from the tag void pins (README: Janet >= 1.41)
RUN git clone --depth 1 --branch "${JANET_VERSION}" https://github.com/janet-lang/janet /tmp/janet \
 && make -C /tmp/janet -j"$(nproc)" \
 && make -C /tmp/janet install \
 && rm -rf /tmp/janet

# jpm, which janet does not ship with
RUN git clone --depth 1 https://github.com/janet-lang/jpm /tmp/jpm \
 && cd /tmp/jpm && janet bootstrap.janet \
 && rm -rf /tmp/jpm

# The framework, out of the checkout: one `jpm install` of the
# repository root installs every package's void/ tree into one merged
# module path, builds void/fdwait's native module and puts the `void`
# binary on PATH (ADR-0020). janet-lang/sqlite3 is separate on purpose
# — void/db-sqlite is a plugin an application opts into, so the bundle
# does not depend on it, and this image carries it because the shop
# runs on either engine.
#
# In two steps, and the split is about the network rather than about
# size: everything that clones from the internet depends on the two
# files that say what the dependencies are, so editing the framework's
# source rebuilds the second step and nothing else.
COPY project.janet /src/project.janet
COPY scripts/packages.janet /src/scripts/packages.janet
RUN cd /src \
 && jpm deps \
 && jpm install https://github.com/janet-lang/sqlite3.git

COPY . /src
RUN cd /src && jpm install

# -------------------------------------------------------------- runtime
FROM debian:bookworm-slim

# libpq5   — void/db-postgres opens it through ffi/ at :start (ADR-0011)
# libssl3  — void/crypto opens libcrypto.so.3 the same way (ADR-0022);
#            bookworm ships OpenSSL 3.0, so scrypt is there and argon2id
#            (which needs 3.2) is not, which is why the default hasher
#            is scrypt and `[:crypto :require]` is not set
# curl     — the healthcheck below, and nothing else
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 openssl curl ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

# janet, jpm's tree (the framework and its dependencies) and the `void`
# binary — everything the builder put under /usr/local and nothing else
COPY --from=build /usr/local /usr/local
RUN ldconfig

RUN useradd --create-home --uid 10001 shop
WORKDIR /app
COPY --chown=shop:shop examples/shop /app
# `[:mail :transport] :file` writes .eml files here in the :dev profile;
# in :prod it is an SMTP relay and this stays empty (a transport that
# keeps mail rather than sending it is a boot error in :prod anyway)
# /app is writable by the application user for exactly two things: the
# .eml files the :file mail transport writes in :dev, and the netrepl's
# unix socket (.void/repl.sock) — `docker compose exec web void repl`
# is a REPL inside the running process, which is a thing void offers
# on purpose (SPEC §4)
RUN mkdir -p /app/tmp/mail && chown -R shop:shop /app /app/tmp
USER shop

ENV VOID_PROFILE=prod \
    VOID_SHOP_DB=postgres \
    VOID_SHOP_REDIS=1 \
    VOID_HTTP__HOST=0.0.0.0 \
    VOID_HTTP__PORT=8080

EXPOSE 8080

# /health is an operator endpoint: void/pressure-http never sheds it,
# so it answers *while* the process is refusing everything else — which
# is exactly when an orchestrator is asking (ADR-0019)
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/health >/dev/null || exit 1

# the web tier. The worker service in docker-compose.yml runs the same
# image with the worker and the scheduler switched on
CMD ["janet", "main.janet"]
