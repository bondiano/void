### void hub — the image.
###
### Build context is the **repository root**, because the framework is
### installed from this checkout rather than from a release:
###
###     docker build -f examples/hub/Dockerfile -t void-hub ../..
###
### (docker-compose.yml does that for you.) An application outside this
### repository replaces the two `jpm` lines below with one dependency in
### its own project.janet — `https://github.com/bondiano/void.git`, the
### whole framework as one bundle.
###
### **This image is what this example already claims to be.** The hub
### has no test-support/paths.janet: it imports `void/...` from an
### installed tree, so `jpm install` here is not a packaging trick, it
### is the same install `scripts/install-tree.janet` does on a laptop
### and CI's clean-machine job does on a runner. The three of them agree
### or one of them is wrong.
###
### Two stages, and the split is the point: everything that needs a
### compiler happens in the first — janet itself, jpm, spork's native
### modules, janet-lang/sqlite3 and void/fdwait's ~60 lines of C — and
### the second carries a janet runtime, the installed tree, three shared
### libraries and the application.

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
# binary on PATH. janet-lang/sqlite3 is separate on purpose
# — void/db-sqlite is a plugin an application opts into, so the bundle
# does not depend on it, and this image carries it because the hub runs
# on either engine (project.janet says the same thing about the same
# two lines).
#
# In two steps, and the split is about the network rather than about
# size: everything that clones from the internet depends on the two
# files that say what the dependencies are, so editing the framework's
# source rebuilds the second step and nothing else. Built the other way
# round — one RUN after `COPY . /src` — every source edit re-clones
# spork and sqlite3, which is slow on a good day and a failed build on
# a network that hiccups.
COPY project.janet /src/project.janet
COPY scripts/packages.janet /src/scripts/packages.janet
RUN cd /src \
 && jpm deps \
 && jpm install https://github.com/janet-lang/sqlite3.git

COPY . /src
RUN cd /src && jpm install

# -------------------------------------------------------------- runtime
FROM debian:bookworm-slim

# libpq5   — void/db-postgres opens it through ffi/ at :start
# libssl3  — two plugins open it the same way: void/crypto for the
#            HMAC every delivery is verified with and
#            void/tls for the two https clients this application has,
#            api.telegram.org and the bucket
# ca-certificates — what those two clients verify against; without it
#            every telegram delivery fails with a certificate error and
#            retries until the queue gives up
# curl     — the healthcheck below, and nothing else
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 openssl curl ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

# janet, jpm's tree (the framework and its dependencies) and the `void`
# binary — everything the builder put under /usr/local and nothing else
COPY --from=build /usr/local /usr/local
RUN ldconfig

RUN useradd --create-home --uid 10001 hub
WORKDIR /app
COPY --chown=hub:hub examples/hub /app
# /app is writable by the application user for two things and neither is
# the point of this deployment: the .eml files the :file mail transport
# writes in :dev, and — if a deployment ever runs on a disk instead of a
# bucket — the local store's root. In :prod both the bodies and the
# letters leave the container.
RUN mkdir -p /app/tmp/mail /app/storage && chown -R hub:hub /app
USER hub

ENV VOID_PROFILE=prod \
    VOID_HUB_DB=postgres \
    VOID_HUB_STORAGE=s3 \
    VOID_HTTP__HOST=0.0.0.0 \
    VOID_HTTP__PORT=8080

EXPOSE 8080

# /health is an operator endpoint: void/pressure-http never sheds it, so
# it answers *while* the process is refusing deliveries — which is
# exactly when an orchestrator is asking
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/health >/dev/null || exit 1

# the web tier. The worker service in docker-compose.yml runs the same
# image with `void jobs work` instead
CMD ["janet", "main.janet"]
