# syntax=docker/dockerfile:1

# SignMind server image.
#
#   docker build -t signmind-backend Backend/     # context is Backend/
#
# The Go binary embeds the compiled admin webui — internal/webui/webui.go does
# `//go:embed all:dist` — so the Next.js static export MUST exist before the Go
# compile. dist/ is gitignored, so on a fresh clone `go build` fails outright
# with "pattern all:dist: no matching files found". Hence stage 1.

# ---- stage 1: Next.js admin webui -> internal/webui/dist --------------------
# Pinned to the BUILD platform: this stage is pure JS codegen, so emulating the
# target arch under QEMU would cost minutes and change nothing in the output.
FROM --platform=$BUILDPLATFORM node:22-alpine AS webui

WORKDIR /src/webui

# Manifests first so `npm ci` stays cached until dependencies actually change.
COPY webui/package.json webui/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY webui/ ./
# `npm run build` = `next build && node scripts/copy-dist.mjs`; copy-dist.mjs
# writes the export to ../../internal/webui/dist, i.e. /src/internal/webui/dist.
RUN npm run build

# ---- stage 2: Go server ----------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
# Must come after `COPY . .` — that copy would otherwise clobber the embed dir.
COPY --from=webui /src/internal/webui/dist ./internal/webui/dist

# modernc.org/sqlite is a pure-Go driver, so CGO stays off and the result is a
# static binary. TARGETOS/TARGETARCH are supplied by buildx; cross-compiling
# from the build platform keeps multi-arch builds at native speed.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -trimpath -ldflags="-s -w" -o /out/signmind ./cmd/server

# ---- stage 3: runtime ------------------------------------------------------
FROM alpine:3.22 AS runtime

# Deliberately no `apk add`. alpine:3.22 already ships ca-certificates-bundle
# (/etc/ssl/certs/ca-certificates.crt, 119 roots) — that is the file crypto/x509
# reads, so the LLM path's outbound HTTPS works as-is. tzdata is dead weight
# too: no package calls time.LoadLocation. Keeping this stage offline makes the
# image reproducible and immune to Alpine mirror outages. busybox already
# supplies the wget used by HEALTHCHECK.
RUN adduser -D -H -u 10001 signmind \
 && mkdir -p /data \
 && chown signmind:signmind /data

COPY --from=build /out/signmind /usr/local/bin/signmind

# config.Load() reads ./.env before the process environment. / deliberately has
# none, so the container is configured purely by env vars — see the compose file.
WORKDIR /
USER signmind

# Defaults only. SIGNMIND_JWT_SECRET and SIGNMIND_AI_SHARED_SECRET have no safe
# default: main.go calls log.Fatal for both when ENV is Prod.
ENV SIGNMIND_HTTP_ADDR=:8080 \
    SIGNMIND_DB_PATH=/data/predictions.db \
    SIGNMIND_AI_ADDR=inference:50051

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/signmind"]
