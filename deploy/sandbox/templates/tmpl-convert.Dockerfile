# syntax=docker/dockerfile:1
#
# E2B sandbox template: tmpl-convert
# ----------------------------------
# Document conversion (MarkItDown + LibreOffice/pandoc) for the ingestion convert
# step. Parsing untrusted user files (PDF/DOCX/XLSX/images with crafted exploits)
# is a real parser-RCE surface — running it inside a disposable, NETWORK-ISOLATED
# microVM contains any parser compromise to a VM that is torn down after the job.
#
# The ingest worker stages the raw file in from S3, runs the conversion via the
# Sandbox port, and gets Markdown back; the pipeline then chunks/embeds as usual.
#
# Egress: NONE. Conversion is fully offline — the fleet egress proxy denies all.
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
