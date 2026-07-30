# syntax=docker/dockerfile:1
#
# Go BFF / gateway / kernel. Multi-stage, static (CGO off), distroless, non-root.
# ONE image, THREE entrypoints (cmd/api, cmd/relay, cmd/worker) — the runtime
# command selects the role (see deploy/docker-compose.prod.yml).
#
# TODO(supply-chain): pin base images by @sha256 digest per
# .github/instructions/devops-cicd.instructions.md (Dependabot manages this).
FROM golang:1.26-bookworm AS build
WORKDIR /src
ENV CGO_ENABLED=0
# Dependency layer first — cached until go.sum changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
ARG TARGETOS TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    for cmd in api relay worker; do \
      GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH:-amd64}" \
      go build -trimpath -ldflags="-s -w" -o "/out/${cmd}" "./cmd/${cmd}"; \
    done

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api    /api
COPY --from=build /out/relay  /relay
COPY --from=build /out/worker /worker
USER nonroot:nonroot
EXPOSE 8080
# Health is exercised via the binary's own `healthcheck` subcommand (compose probe);
# distroless has no shell/curl. /livez + /readyz are served on :8080 for the edge.
ENTRYPOINT ["/api"]
