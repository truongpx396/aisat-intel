# syntax=docker/dockerfile:1
#
# E2B sandbox template: tmpl-crawl
# --------------------------------
# The headless-browser fetch toolchain (Crawl4AI + Playwright/Chromium), moved OFF
# the shared Python worker pods and INTO a microVM. This retires the bespoke
# backend-python/Dockerfile.crawl: the same toolchain, now hardware-isolated.
#
# The microVM is booted by the sandbox fleet; the crawl ORCHESTRATOR (a thin role
# consuming ingestion.crawl.<ws>) stages the target URL in and runs the fetch via
# the Sandbox port — there is no long-running CMD here, the VM just carries tools.
#
# Egress: SSRF allowlist only (https, public IPs after full A/AAAA resolution, no
# redirects, bounded size/time) — enforced by the fleet egress proxy, not this image.
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
