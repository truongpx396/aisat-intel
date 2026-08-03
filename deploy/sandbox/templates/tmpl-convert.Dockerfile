# syntax=docker/dockerfile:1
#
# Sandbox template: tmpl-convert
# ------------------------------
# Document conversion (MarkItDown + LibreOffice/pandoc) for the ingestion convert
# step. Parsing untrusted user files (PDF/DOCX/XLSX/images with crafted exploits)
# is a real parser-RCE surface — running it in a disposable, NETWORK-ISOLATED
# sandbox contains any parser compromise to something torn down after the job.
#
# THIS IMAGE *IS* THE SANDBOX — no nesting. One instance per convert job; the
# boundary SHAPE comes from SANDBOX_KIND (container / pod / microVM rootfs).
#
# **This is the template that ratchets to gVisor** (SANDBOX_RUNTIME=runsc, the
# orthogonal runtime axis). Document parsers have a worse CVE history than Chrome
# AND no internal sandbox of their own, making this the higher-risk surface of the
# two Phase-1 templates — higher than tmpl-crawl, which keeps Chromium's own.
# runsc needs no /dev/kvm, so it is free on any Linux host or node.
#
# The ingest worker stages the raw file in from S3, runs the conversion via the
# Sandbox port, and gets Markdown back; the pipeline then chunks/embeds as usual.
# No bind mounts, ever — files move via S3 staging only (invariant 9).
#
# Egress: NONE. Conversion is fully offline — denied at the proxy + NetworkPolicy.
#
# BUILD CONTEXT IS `backend-python/`, NOT THIS DIRECTORY — the COPY below needs
# pyproject.toml + uv.lock, which live there:
#   docker build -f deploy/sandbox/templates/tmpl-convert.Dockerfile \
#     -t aisat-sandbox-convert backend-python/
# MarkItDown is never named here: it arrives via `uv sync --extra convert`, so the
# parser set stays version-locked to the app's uv.lock rather than drifting on its own.
#
# Contract: specs/001-contextengine-mvp/contracts/sandbox-runtime.md
# TODO(supply-chain): pin the base image by @sha256.
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /home/user

# System converters MarkItDown shells out to (office formats, PDFs, images).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libreoffice-common libreoffice-writer libreoffice-calc \
        pandoc poppler-utils tesseract-ocr ffmpeg \
    && rm -rf /var/lib/apt/lists/*

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# The `convert` optional-dependency group carries markitdown + parsers.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev --extra convert
ENV PATH="/home/user/.venv/bin:$PATH"
