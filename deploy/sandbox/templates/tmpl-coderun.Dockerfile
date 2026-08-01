# syntax=docker/dockerfile:1
#
# E2B sandbox template: tmpl-coderun  (Phase 2)
# ---------------------------------------------
# The runtime for AGENT-GENERATED file-manipulation scripts (the `run_script` /
# `transform_files` Category-D tools). The agent writes a script; it runs HERE, in a
# throwaway microVM with only the run's working files staged in — never on a worker pod,
# never with ambient credentials.
#
# Governance (see the contract): HITL-gated (approval_request kind='run_script'),
# metered as operation_type='sandbox.run_script', output re-enters the index only
# through the human accept gate. This template ships no secrets and no DB/Qdrant client.
#
# Egress: NONE by default; opt-in per-run allowlist, HITL-gated. A script that needs AI
# or knowledge must call back through the LLM Gateway / MCP chokepoint — never directly.
#
# Contract: specs/001-contextengine-mvp/contracts/sandbox-runtime.md
# TODO(supply-chain): pin the base image by @sha256.
FROM python:3.12-slim

# Node runtime alongside Python for polyglot generated scripts.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/user
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# A small, audited standard toolkit for file manipulation — NO network/AI/DB clients.
RUN pip install --no-cache-dir \
        pandas openpyxl python-docx pypdf pillow

# The sandbox stages the working set under ./work; generated code reads/writes only here.
RUN mkdir -p /home/user/work
