# The load generators in a container next to the apps:
# wrk (max throughput) + wrk2 (latency under fixed rate — the only
# honest latency, wrk suffers coordinated omission).
#
#   docker build -t void-bench-loadgen bench/loadgen
#   docker run --rm --network host -v "$PWD/bench:/bench" \
#     -e BENCH_BODY_FILE=/bench/payloads/b1-order.json void-bench-loadgen \
#     wrk2 -t4 -c64 -d60s -R16000 --latency http://127.0.0.1:8100/
#
# (--network host is Linux-only; on macOS target host.docker.internal
# instead of 127.0.0.1.)
FROM debian:bookworm-slim AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential libssl-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/wg/wrk /src/wrk \
    && make -C /src/wrk -j"$(nproc)"
RUN git clone --depth 1 https://github.com/giltene/wrk2 /src/wrk2 \
    && make -C /src/wrk2 -j"$(nproc)"

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/wrk/wrk /usr/local/bin/wrk
COPY --from=build /src/wrk2/wrk /usr/local/bin/wrk2
CMD ["wrk"]
