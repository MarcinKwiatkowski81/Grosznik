FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git \
    libssl-dev libsqlite3-dev libcurl4-openssl-dev \
    liblua5.4-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Docker build context = parent directory zawierający HTTPD, Telebot, Grosznik
COPY HTTPD    /build/HTTPD
COPY Telebot  /build/Telebot
COPY Grosznik /build/Grosznik

# Build HTTPD
RUN cd /build/HTTPD && cmake -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j$(nproc)

# Build Telebot
RUN cd /build/Telebot && cmake -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j$(nproc)

# Build Grosznik
RUN cd /build/Grosznik && cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DHTTPD_DIR=/build/HTTPD \
      -DTELEBOT_DIR=/build/Telebot \
    && cmake --build build -j$(nproc)

# ── Runtime image ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libsqlite3-0 libcurl4 liblua5.4-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/Grosznik/build/grosznik          /app/grosznik
COPY --from=builder /build/Grosznik/build/modules/           /app/modules/
COPY --from=builder /build/HTTPD/build/modules/lua_module.so /app/modules/
COPY --from=builder /build/Grosznik/www                      /app/www

RUN mkdir -p /data
VOLUME ["/data"]

EXPOSE 8080
CMD ["/app/grosznik"]
