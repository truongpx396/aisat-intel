# syntax=docker/dockerfile:1
#
# Sandbox template: tmpl-coderun  (Phase 2)
# -----------------------------------------
# The runtime for AGENT-GENERATED file-manipulation scripts (the `run_script` /
# `transform_files` Category-D tools). The agent writes a script; it runs HERE, in a
# throwaway sandbox with only the run's working files staged in — never in the agent
# process, never with ambient credentials.
#
# THIS IMAGE *IS* THE SANDBOX — no nesting. One instance per run, torn down after.
#
# BOUNDARY: gVisor (runtime=runsc) + max_runs_per_sandbox=1, on the ordinary k8s_pod
# path. NOT a microVM by default — gVisor's designed purpose IS untrusted code, and
# Google runs multi-tenant customer code on it (Cloud Run, App Engine, GKE Sandbox).
# A Python transform script is also a much better gVisor fit than Chromium, which is
# gVisor's pathological case and why tmpl-crawl stays on runc.
#
# A microVM (SANDBOX_KIND=e2b_*) is STRONGER but NOT REQUIRED. Buy it only if the
# threat model changes: third-party-authored code, hostile tenants, or a compliance
# rule that names hardware isolation. Consequence: the KVM/*.metal pool may never
# need to exist — this template no longer gates on it.
#
# NEVER pooled: max_runs=1 is the non-negotiable property (an instance that has run
# model-authored code is never reused). warm_pool is a separate, cost-only knob —
# pre-warming a PRISTINE instance is not a compromise. See e2b.toml.
#
# Governance (see the contract): HITL-gated (approval_request kind='run_script'),
# metered as operation_type='sandbox.run_script', output re-enters the index only
# through the human accept gate. This template ships no secrets and no DB/Qdrant client.
#
# Egress: NONE by default; opt-in per-run allowlist, HITL-gated. A script that needs AI
# or knowledge must call back through the LLM Gateway / MCP chokepoint — never directly.
#
# BUILD CONTEXT IS `backend-python/`, NOT THIS DIRECTORY — the COPY below needs
# pyproject.toml + uv.lock, which live there:
#   docker build -f deploy/sandbox/templates/tmpl-coderun.Dockerfile \
#     -t aisat-sandbox-coderun backend-python/
# THE INSTALLED TOOLKIT IS A CONTRACT, NOT AN IMPLEMENTATION DETAIL. Egress is DENY,
# so there is no `pip install` at runtime: if the agent generates `import polars` and
# polars is not below, the run just fails. The list under "analysis toolkit" is
# therefore the exact surface the model may code against, and it MUST be enumerated in
# the run_script tool description — otherwise the model will confidently import things
# that do not exist. Changing that list is a tool-contract change, not a Dockerfile tweak.
# This template ships NO secrets and no DB/Qdrant/network client — see invariant 1.
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

# The analysis toolkit. Deliberately curated and deliberately small: every entry is a
# capability the agent is allowed to assume, and nothing here reaches the network, an
# LLM, or a database. Keep in sync with the run_script tool description.
#   pandas/numpy   tabular analysis      openpyxl/xlrd  spreadsheets
#   pyarrow        parquet + fast CSV    python-docx    Word
#   pypdf          PDF text              pillow         images
#   matplotlib     charts -> files_out (headless; MPLBACKEND=Agg below)
RUN pip install --no-cache-dir \
        pandas numpy pyarrow openpyxl xlrd python-docx pypdf pillow matplotlib

# A read-only rootfs means every tool that wants a cache/config dir must be pointed at
# the tmpfs, or it fails at import time rather than at use time. matplotlib is the
# usual offender; HOME matters for anything else that scribbles a dotfile.
ENV HOME=/tmp \
    MPLBACKEND=Agg \
    MPLCONFIGDIR=/tmp/.mpl \
    XDG_CACHE_HOME=/tmp/.cache

# The sandbox stages the working set under ./work; generated code reads/writes only here.
RUN mkdir -p /home/user/work
