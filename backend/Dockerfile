FROM rust:1.91 AS builder

WORKDIR /app

COPY Cargo.toml Cargo.lock ./
COPY src ./src

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/target/release/backend /app/backend

ENV SKYBRIDGE_BIND_HOST=0.0.0.0 \
  SKYBRIDGE_BIND_PORT=8080

EXPOSE 8080

RUN useradd --system --uid 10001 --no-create-home appuser
USER 10001

CMD ["/app/backend"]

