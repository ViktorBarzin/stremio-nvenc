# syntax=docker/dockerfile:1
#
# stremio-nvenc — self-hosted Stremio streaming server (bundled Stremio web
# client + unmodified stremio server.js + nginx single-origin + HTTP basic-auth)
# re-based to glibc with an NVENC-capable ffmpeg.
#
# Derived from tsaridas/stremio-docker (MIT, Copyright (c) 2023 Andreas Tsarida —
# see LICENSE). Two deliberate departures from upstream, both documented in
# README.md:
#   1. The final stage is Ubuntu 22.04 jammy (glibc), NOT Alpine (musl). The NVIDIA
#      encode userspace (libnvidia-encode / libnvcuvid / libcuda, injected at
#      runtime by the NVIDIA container toolkit) is glibc-only, so a musl base
#      silently falls back to CPU transcoding (infra#80 spec, workstream A).
#   2. ffmpeg is Jellyfin's prebuilt NVENC .deb (ships h264_nvenc / hevc_nvenc /
#      NVDEC-cuda), replacing tsaridas's from-source VAAPI jellyfin-ffmpeg build.
#
# Build target: linux/amd64 ONLY (the jellyfin-ffmpeg deb + NVENC are amd64 here).

############################################################################
# Stage 1: builder-web — build and JS-bundle the Stremio web client, and fetch
# the unmodified stremio server.js. Carried over VERBATIM from tsaridas (runs on
# Alpine). Safe to build on musl even though the final image is glibc: webpack
# output is platform-independent JS/HTML/CSS and server.js is pure Node run by
# the glibc `node` in the final stage — neither links musl.
############################################################################
FROM alpine:3.24 AS base

RUN --mount=type=cache,id=apk-base,target=/var/cache/apk \
  apk update && apk upgrade && apk add --no-cache nodejs npm

FROM base AS builder-web

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

WORKDIR /srv
RUN apk add --no-cache git wget

ARG BRANCH=development
RUN REPO="https://github.com/Stremio/stremio-web.git"; if [ "$BRANCH" == "release" ];then git clone "$REPO" --depth 1 --branch $(git ls-remote --tags --refs $REPO | awk '{print $2}' | sort -V | tail -n1 | cut -d/ -f3); else git clone --depth 1 --branch "$BRANCH" https://github.com/Stremio/stremio-web.git; fi

WORKDIR /srv/stremio-web

RUN sed -i "s#const COMMIT_HASH = execSync('git rev-parse HEAD').toString().trim();#const GIT_COMMIT = execSync('git rev-parse HEAD').toString().trim();\\nconst BUILD_LABEL = process.env.COMMIT_HASH ? String(process.env.COMMIT_HASH).replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/-+/g, '-').replace(/^-+|-+\$/g, '') : '';\\nconst COMMIT_HASH = BUILD_LABEL ? BUILD_LABEL + '-' + GIT_COMMIT : GIT_COMMIT;\\nprocess.env.COMMIT_HASH = COMMIT_HASH;#" webpack.config.js

COPY ./load_localStorage.js ./src/load_localStorage.js
RUN sed -i "/entry: {/a \\        loader: './src/load_localStorage.js'," webpack.config.js

RUN npm install -g pnpm@11 --force
RUN pnpm install --frozen-lockfile --reporter=silent
ARG COMMIT_HASH=
RUN COMMIT_HASH=$COMMIT_HASH pnpm run build

RUN wget $(wget -O- https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt) && wget -mkEpnp -nH "https://app.strem.io/" "https://app.strem.io/worker.js" "https://app.strem.io/images/stremio.png" "https://app.strem.io/images/empty.png" -P build/shell/ || true

############################################################################
# Stage 2: final — glibc runtime on Ubuntu 22.04 jammy. Assembles the server
# exactly as tsaridas wires it (server.js + web build + nginx + entrypoint),
# with the NVENC jellyfin-ffmpeg deb in place of the dropped VAAPI ffmpeg stage.
############################################################################
# Ubuntu 22.04 (jammy), moved from Debian 11 bullseye on 2026-10-09 because
# bullseye's LTS ended 2026-08-31. Not Debian 12: Stremio's server needs ffmpeg
# 4.x, and jellyfin-ffmpeg 4.4.1-4 (the last 4.x NVENC .deb) ships no bookworm
# build. Jammy has one, and jammy standard support runs to 2027-04.
#
# RENOVATE (ADR-0030, for the agent migrating this repo): this image has no
# automatic updates yet. Two things to wire up:
#   1. a renovate.json here so Renovate bumps the pinned bases (alpine, ubuntu)
#      and the jellyfin-ffmpeg .deb URL below (hold it on 4.x: Stremio's server
#      does not support ffmpeg 5+);
#   2. a scheduled rebuild (e.g. a weekly `schedule:` trigger in
#      .github/workflows/build.yml). The Stremio web client (BRANCH=development)
#      and server.js are fetched fresh at build time, so a rebuild is the only
#      thing that updates them; Renovate cannot see those.
FROM ubuntu:22.04 AS final

ARG VERSION=main
LABEL org.opencontainers.image.source=https://github.com/tsaridas/stremio-docker
LABEL org.opencontainers.image.description="Stremio Web Player and Server (glibc + NVENC hardware transcoding)"
LABEL org.opencontainers.image.licenses=MIT
LABEL version=${VERSION}

# Runtime deps:
#   nodejs         — runs server.js and certificate.js (installed from NodeSource
#                    below, NOT the distro apt repo: jammy ships Node 12,
#                    which lacks the global `fetch`/`AbortController` certificate.js
#                    uses and is far older than upstream's Node 22; NodeSource
#                    Node 22 matches tsaridas's Alpine node and bundles npm).
#                    See README "Node version".
#   nginx          — single-origin reverse proxy + basic-auth gate (config in nginx/)
#   apache2-utils  — provides htpasswd, used by the entrypoint to build the auth file
#   ca-certificates, curl, gnupg — TLS trust + NodeSource setup + egress
#   libssl3       — already in the base image; listed so the build pulls the
#                    current jammy security update instead of whatever the
#                    base image snapshot shipped (Trivy flagged 1.29).
# npm is removed after the NodeSource install: nothing at runtime calls it (the
# entrypoint runs `node` directly), and its bundled dependencies carry HIGH
# CVEs that even the newest npm release has not picked up.
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      libssl3 \
      nginx \
      apache2-utils \
      procps \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /usr/lib/node_modules/npm /usr/bin/npm /usr/bin/npx \
  && rm -rf /var/lib/apt/lists/*

# tsaridas's nginx.conf declares `user nginx;`. the distro nginx package runs as
# www-data and creates no `nginx` user, so create it here — this lets nginx.conf
# stay byte-identical to upstream (the only intentional nginx edit is the
# torrent-path auth re-enable in nginx/{http.d/default.conf,https.conf}).
RUN groupadd --system nginx \
  && useradd --system --no-create-home --shell /usr/sbin/nologin --gid nginx nginx

# infra#80: the distro nginx (1.18 on both bullseye and jammy) predates `application/wasm` in its
# default mime.types, so the Stremio core WASM (stremio_core_web_bg.wasm) is
# served as application/octet-stream. WebAssembly.instantiateStreaming() then
# rejects it and the web client falls back to the slower instantiate() path,
# which can hard-fail core init on stricter engines / stale caches -> the whole
# board ("all popular recommendations") fails to load. Register the correct type.
RUN grep -q 'application/wasm' /etc/nginx/mime.types \
  || sed -i 's#^}#    application/wasm                  wasm;\n}#' /etc/nginx/mime.types

# jellyfin-ffmpeg NVENC build, pinned to v4.4.1-4 exactly. Installed via apt so
# its runtime library dependencies resolve from the jammy repos. Binaries land
# at /usr/lib/jellyfin-ffmpeg/{ffmpeg,ffprobe} (see FFMPEG_BIN/FFPROBE_BIN below).
ADD https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v4.4.1-4/jellyfin-ffmpeg_4.4.1-4-jammy_amd64.deb /tmp/jellyfin-ffmpeg.deb
RUN apt-get update \
  && apt-get install -y --no-install-recommends /tmp/jellyfin-ffmpeg.deb \
  && rm -f /tmp/jellyfin-ffmpeg.deb \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/stremio-server

# --- Server assembly (carried over from tsaridas verbatim; only the ffmpeg
#     source changed) --------------------------------------------------------
COPY --from=builder-web /srv/stremio-web/build ./build
COPY --from=builder-web /srv/stremio-web/server.js ./

COPY ./nginx/ /etc/nginx/
COPY ./stremio-web-service-run.sh ./
COPY ./certificate.js ./
RUN chmod +x stremio-web-service-run.sh
COPY ./restart_if_idle.sh ./
RUN chmod +x restart_if_idle.sh
COPY localStorage.json ./

# --- Environment (tsaridas's ENV block, verbatim EXCEPT FFMPEG_BIN/FFPROBE_BIN,
#     which now point at the jellyfin-ffmpeg NVENC binaries) -------------------
ENV FFMPEG_BIN=/usr/lib/jellyfin-ffmpeg/ffmpeg
ENV FFPROBE_BIN=/usr/lib/jellyfin-ffmpeg/ffprobe
# default https://app.strem.io/shell-v4.4/
ENV WEBUI_LOCATION=
ENV WEBUI_INTERNAL_PORT=
ENV OPEN=
ENV HLS_DEBUG=
ENV DEBUG=
ENV DEBUG_MIME=
ENV DEBUG_FD=
ENV FFMPEG_DEBUG=
ENV FFSPLIT_DEBUG=
ENV NODE_DEBUG=
ENV NODE_ENV=production
ENV HTTPS_CERT_ENDPOINT=
ENV DISABLE_CACHING=
# disable or enable
ENV READABLE_STREAM=

# Custom application path for storing server settings, certificates, etc
# You can change this but server.js always saves cache to /root/.stremio-server/
ENV APP_PATH=
ENV NO_CORS=1
ENV CASTING_DISABLED=

# Do not change the above ENVs.

# Set this to your lan or public ip.
ENV IPADDRESS=
# Set this to your domain name
ENV DOMAIN=
# Set this to the path to your certificate file
ENV CERT_FILE=

# Server url
ENV SERVER_URL=
ENV AUTO_SERVER_URL=0

VOLUME ["/root/.stremio-server"]

# Expose only the nginx single origin (the server's own 11470 stays internal).
EXPOSE 8080

ENTRYPOINT []

CMD ["./stremio-web-service-run.sh"]
