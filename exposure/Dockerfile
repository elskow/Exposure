# Optimized multi-stage Dockerfile for Phoenix/Elixir
#
# Build: docker build -t exposure .
# Run:   docker run -d -p 4000:4000 \
#          -e SECRET_KEY_BASE=... \
#          -e DATABASE_PATH=/app/data/exposure.db \
#          -e ADMIN_USERS="admin:password" \
#          -v exposure_data:/app/data \
#          exposure

ARG ELIXIR_VERSION=1.16.3
ARG OTP_VERSION=26.0.2
ARG DEBIAN_VERSION=bookworm-20251117-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# =============================================================================
# STAGE 1: Build
# =============================================================================
FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
# - build-essential: compilation tools
# - git: for fetching git dependencies
# - libvips-dev: for image processing (Image library)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libvips-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod
# Disable JIT for cross-compilation compatibility (QEMU)
ENV ERL_FLAGS="+JPperf true"

# Install dependencies first (better layer caching)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Copy compile-time config
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/

# Compile deps one by one to avoid module loading issues in QEMU
# Clean any stale build artifacts first, then compile deps
RUN rm -rf _build deps/.mix deps/.elixir_ls 2>/dev/null || true && \
    mix deps.compile

# Copy application code
COPY priv priv
COPY lib lib
COPY assets assets

# Compile assets (tailwind + esbuild)
RUN mix assets.deploy

# Compile application
RUN mix compile

# Copy runtime config (doesn't require recompilation)
COPY config/runtime.exs config/

# Copy release overlays
COPY rel rel

# Build the release
RUN mix release

# =============================================================================
# STAGE 2: Runtime
# =============================================================================
FROM ${RUNNER_IMAGE}

# Install runtime dependencies only
# - libstdc++6: C++ standard library (required by BEAM)
# - openssl: for crypto
# - libncurses5: for remote console
# - locales: for UTF-8 support
# - ca-certificates: for HTTPS
# - libvips42: runtime for image processing (smaller than libvips-dev)
# - tini: init process to reap zombie processes
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    ca-certificates \
    libvips42 \
    tini \
    && rm -rf /var/lib/apt/lists/*

# Set up locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Create non-root user for security
RUN groupadd --gid 1000 exposure && \
    useradd --uid 1000 --gid exposure --shell /bin/bash --create-home exposure

# Create data directory for SQLite database and images
RUN mkdir -p /app/data /app/priv/static/images/places && \
    chown -R exposure:exposure /app

# Set runtime environment
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Copy the release from builder
COPY --from=builder --chown=exposure:exposure /app/_build/prod/rel/exposure ./

USER exposure

# Expose the application port
EXPOSE 4000

# Use tini as init to properly handle signals and reap zombie processes
ENTRYPOINT ["/usr/bin/tini", "--"]

# Run the server
CMD ["/app/bin/server"]
