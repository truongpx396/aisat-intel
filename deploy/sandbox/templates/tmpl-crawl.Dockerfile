# syntax=docker/dockerfile:1
#
# Sandbox template: tmpl-crawl
# ----------------------------
# The headless-browser fetch toolchain (Crawl4AI + Playwright/Chromium), moved OFF
# the shared Python worker pods and into its own sandbox. This retires the bespoke
# backend-python/Dockerfile.crawl: the same toolchain, now isolated.
#
# THIS IMAGE *IS* THE SANDBOX — there is no nesting. One instance of this image is
# started per crawl job (from the warm pool), and crawl4ai + Chromium run as
# processes inside it. The boundary SHAPE is chosen by SANDBOX_KIND, not here:
#   docker       -> this image runs as a container      (local macOS, DO droplet)
#   k8s_pod      -> this image runs as a pod            (k3s / EKS)
#   e2b_selfhost -> this image is the microVM rootfs    (Phase 2)
# One image, three boundary shapes, zero rebuilds.
#
# The crawl ORCHESTRATOR (a thin role consuming ingestion.crawl.<ws>) stages the
# target URL in and runs the fetch via the Sandbox port — there is no long-running
# CMD here, the image just carries tools.
#
# Isolation runtime is the ORTHOGONAL axis (SANDBOX_RUNTIME): tmpl-crawl stays on
# runc — Chromium is gVisor's worst case (syscall-heavy, needs --no-sandbox) and it
# already ships its own multi-process sandbox. tmpl-convert is the template that
# ratchets to runsc. See contracts/sandbox-runtime.md § the isolation ratchet.
#
# Egress: SSRF allowlist only (https, public IPs after full A/AAAA resolution, no
# redirects, bounded size/time) — enforced by the egress proxy + NetworkPolicy, not
# this image. No bind mounts, ever: files move via S3 staging (invariant 9).
#
# BUILD CONTEXT IS `backend-python/`, NOT THIS DIRECTORY — the COPY below needs
# pyproject.toml + uv.lock, which live there:
#   docker build -f deploy/sandbox/templates/tmpl-crawl.Dockerfile \
#     -t aisat-sandbox-crawl backend-python/
# The toolchain is never named here: it arrives via `uv sync --extra crawl`, so it
# stays version-locked to the app's uv.lock (Playwright's package cannot drift from
# the Chromium baked into the base image).
#
# Contract: specs/001-contextengine-mvp/contracts/sandbox-runtime.md
# TODO(supply-chain): pin the base image by @sha256; keep the playwright version in
# lockstep with pyproject.toml's `crawl` extra (browsers must match the base tag).
FROM mcr.microsoft.com/playwright/python:v1.49.0-jammy

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /home/user

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# The `crawl` optional-dependency group carries crawl4ai + playwright.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev --extra crawl
ENV PATH="/home/user/.venv/bin:$PATH"
