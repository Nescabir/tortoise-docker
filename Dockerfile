# syntax=docker/dockerfile:1.7
# Tortoise WoW (Shyalya/tortoise-wow) — Ubuntu 22.04 build for GHCR + compose.
# Build-arg BUILD_PLAYERBOTS controls whether the playerbots module is compiled in.

ARG UBUNTU_VERSION=22.04

# -----------------------------------------------------------------------------
# Builder
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG BUILD_PLAYERBOTS=ON
ARG USE_EXTRACTORS=OFF
ARG SOURCE_REPO=https://github.com/Shyalya/tortoise-wow.git
ARG SOURCE_REF=playerbots-integration-gh
ARG CMAKE_BUILD_TYPE=Release
ARG CMAKE_INSTALL_PREFIX=/opt/turtle
ARG BUILD_JOBS=2
ARG CPU_TARGET=x86-64-v2
# Resolved upstream commit SHA, passed in by CI. Declaring it right before the
# clone RUN busts the layer cache whenever upstream actually moves, without
# forcing a full rebuild when nothing changed (see issue #6).
ARG SOURCE_COMMIT=""

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libace-dev \
        libboost-all-dev \
        default-libmysqlclient-dev \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN echo "Cloning ${SOURCE_REPO}#${SOURCE_REF} @ ${SOURCE_COMMIT:-unresolved}" \
    && git clone --depth 1 --branch "${SOURCE_REF}" "${SOURCE_REPO}" tortoise-wow

WORKDIR /src/tortoise-wow

ARG EXTRACTORS_ONLY=OFF

# The upstream build currently adds -march=native. That makes a published
# image depend on the CPU that built it and can emit instructions unavailable
# on otherwise supported hosts. Keep the image portable across x86-64 CPUs.
RUN if grep -q -- '-march=native' CMakeLists.txt; then \
        sed -i "s/-march=native/-march=${CPU_TARGET}/g" CMakeLists.txt; \
    fi \
    && if grep -q -- '-march=native' CMakeLists.txt; then \
         echo "CMakeLists.txt still contains -march=native" >&2; \
         exit 1; \
       fi

RUN cmake -B build \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DCMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}" \
        -DBUILD_PLAYERBOTS="${BUILD_PLAYERBOTS}" \
        -DUSE_EXTRACTORS="${USE_EXTRACTORS}" \
        -DALLOW_TURTLE_ADDONS=ON \
    && if [ "${EXTRACTORS_ONLY}" = "ON" ]; then \
         cmake --build build -j"${BUILD_JOBS}" --target mapextractor vmapextractor vmap_assembler MoveMapGen \
         && mkdir -p /opt/turtle/bin \
         && find build -type f -executable \
              \( -name mapextractor -o -name vmapextractor -o -name vmap_assembler -o -name MoveMapGen \) \
              -exec cp -a '{}' /opt/turtle/bin/ ';'; \
       else \
         cmake --build build -j"${BUILD_JOBS}" \
         && cmake --install build; \
       fi \
    && git rev-parse HEAD > /opt/turtle/SOURCE_COMMIT \
    && rm -rf build

# Keep SQL needed for first-time DB init + AutoUpdate path.
RUN mkdir -p /opt/turtle/sql \
    && cp -a sql/create_databases.sql sql/base sql/database_updates /opt/turtle/sql/ \
    && if [ -d src/modules/PlayerBots/sql ]; then \
         mkdir -p /opt/turtle/sql/playerbots \
         && cp -a src/modules/PlayerBots/sql/. /opt/turtle/sql/playerbots/; \
       fi

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG BUILD_PLAYERBOTS=ON
ARG CMAKE_INSTALL_PREFIX=/opt/turtle
ARG CPU_TARGET=x86-64-v2

LABEL org.opencontainers.image.title="tortoise-docker" \
      org.opencontainers.image.description="Turtle WoW / Tortoise server (realmd + mangosd)" \
      org.opencontainers.image.source="https://github.com/Shyalya/tortoise-wow" \
      org.opencontainers.image.licenses="GPL-2.0" \
      org.opencontainers.image.cpu.target="${CPU_TARGET}"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    TURTLE_HOME=/opt/turtle \
    PLAYERBOTS_BUILT=${BUILD_PLAYERBOTS} \
    PATH=/opt/turtle/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libace-7.0.6 \
        libboost-atomic1.74.0 \
        libboost-chrono1.74.0 \
        libboost-date-time1.74.0 \
        libboost-filesystem1.74.0 \
        libboost-iostreams1.74.0 \
        libboost-program-options1.74.0 \
        libboost-regex1.74.0 \
        libboost-serialization1.74.0 \
        libboost-system1.74.0 \
        libboost-thread1.74.0 \
        libmysqlclient21 \
        libssl3 \
        zlib1g \
        libbz2-1.0 \
        libreadline8 \
        libncurses6 \
        mariadb-client \
        tini \
        gosu \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 turtle \
    && useradd --uid 1000 --gid turtle --home-dir /opt/turtle --shell /usr/sbin/nologin turtle

COPY --chown=1000:1000 --from=builder /opt/turtle /opt/turtle
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/init-db.sh /usr/local/bin/init-db.sh
COPY docker/render-config.sh /usr/local/bin/render-config.sh
COPY docker/repair-migrations.sh /usr/local/bin/repair-migrations.sh
COPY --chown=1000:1000 docker/character-inventory-copy.sql /opt/turtle/sql/character-inventory-copy.sql

RUN chmod +x /usr/local/bin/entrypoint.sh \
              /usr/local/bin/init-db.sh \
              /usr/local/bin/render-config.sh \
              /usr/local/bin/repair-migrations.sh \
    && mkdir -p /opt/turtle/data /opt/turtle/logs /opt/turtle/run /var/lib/turtle-init \
    && mkdir -p /opt/turtle/etc.dist \
    && cp /opt/turtle/etc/*.conf.dist /opt/turtle/etc.dist/ \
    && chown -R turtle:turtle /opt/turtle/data /opt/turtle/etc.dist /opt/turtle/run /opt/turtle/logs /var/lib/turtle-init

WORKDIR /opt/turtle/bin

EXPOSE 3724/tcp 8090/tcp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["mangosd"]
