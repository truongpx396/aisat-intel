# syntax=docker/dockerfile:1
#
# Python ML / agent tier (FastAPI routers, LangGraph agent, ingestion, MCP server).
# Multi-stage with UV; deps resolved from the frozen lockfile, non-root runtime.
# ONE image, MANY roles — the compose `command` selects api / worker / mcp.
#
# TODO(supply-chain): pin base images by @sha256 digest; pin the UV tag.
FROM python:3.14-slim AS build
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
# Dependency layer first — cached until the lockfile changes.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

FROM python:3.14-slim
RUN groupadd -g 10001 appuser \
 && useradd -m -u 10001 -g appuser appuser \
 && apt-get update \
 && apt-get install -y --no-install-recommends curl tini \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=appuser:appuser /app /app
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8000/livez || exit 1
# tini reaps zombies + forwards signals; default role is the FastAPI API.
ENTRYPOINT ["tini", "--"]
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
