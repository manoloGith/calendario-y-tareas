# Servidor de sincronización zero-knowledge de Calendario y Tareas.
# Construir (desde la raíz del repositorio):  docker build -f server/Dockerfile -t calendario-zk .
FROM rust:1-bookworm AS build
WORKDIR /src
COPY core ./core
COPY server ./server
RUN cd server && cargo build --release --locked

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --home /data calzk && mkdir -p /data && chown calzk /data \
 && apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/server/target/release/calendario-zk-server /usr/local/bin/calendario-zk-server
USER calzk
ENV CALZK_DB=/data/calendario-zk.db CALZK_LISTEN=0.0.0.0:8787 CALZK_REGISTER=true
VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=60s --timeout=5s CMD curl -fs http://127.0.0.1:8787/v1/health || exit 1
CMD ["calendario-zk-server"]
