# Backend Dockerfile - Multi-stage build for optimized production image
FROM rust:1.75-slim AS builder

WORKDIR /app

# Install required dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy Cargo files
COPY Cargo.toml Cargo.lock ./

# Create a dummy main.rs to cache dependencies
RUN mkdir src && \
    echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src

# Copy source code
COPY src ./src

# Build the application (this will use cached dependencies)
RUN touch src/main.rs && \
    cargo build --release

# Production stage - Minimal image
FROM debian:bookworm-slim

# Install CA certificates and other runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN useradd -m -u 1001 appuser

WORKDIR /app

# Copy the binary from builder
COPY --from=builder /app/target/release/sinan-backend /app/sinan-backend

# Change ownership
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Expose port 3000
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/app/sinan-backend", "--health-check"] || exit 1

# Run the application
CMD ["/app/sinan-backend"]

