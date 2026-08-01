# Sandbox Runtime — self-hosted E2B tier

The **single chokepoint for isolated code / tool execution**. Every untrusted browser
(crawl4ai), untrusted file parser (MarkItDown), or model-authored script (future
code-gen tools) runs inside an **ephemeral, network-isolated microVM** — never on a
shared worker pod.

Contract (source of truth): [`../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md`](../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md).
This directory is the standalone-tier config home, mirroring [`deploy/do/llm-gateway/`](../do/llm-gateway/).

## What runs here

| Template | Toolchain | Consumer |
|----------|-----------|----------|
| [`templates/tmpl-crawl.Dockerfile`](templates/tmpl-crawl.Dockerfile) | Chromium + Playwright + Crawl4AI | crawl orchestrator (`ingestion.crawl.<ws>`) |
| [`templates/tmpl-convert.Dockerfile`](templates/tmpl-convert.Dockerfile) | MarkItDown + LibreOffice / pandoc | ingest convert step (`ingestion.{pdf,docx,image}.<ws>`) |
| [`templates/tmpl-coderun.Dockerfile`](templates/tmpl-coderun.Dockerfile) | Python + Node runtime (no secrets) | agent code-gen tool `run_script` / `transform_files` *(Phase 2)* |

Templates are declared in [`templates/e2b.toml`](templates/e2b.toml) and built + published to
the self-hosted registry by the sandbox build step (`make sandbox-templates`, TODO).

## App wiring (the swap seam)

Business code never talks to a sandbox vendor SDK — it calls the Python `Sandbox` port,
which forwards to this tier. Selected by config (same discipline as `LLM_GATEWAY_*`):

```bash
SANDBOX_KIND=e2b_selfhost      # e2b_selfhost | e2b_cloud | daytona | local_docker
SANDBOX_URL=http://sandbox-orchestrator:49983
SANDBOX_API_KEY=...            # fleet control-plane auth (self-host) or E2B Cloud key
```

## Self-hosting: the KVM constraint

Firecracker microVMs need **`/dev/kvm`** (hardware virtualization). **Standard EKS nodes
(`t3.large`) and standard DigitalOcean droplets do NOT expose nested virtualization**, so
the fleet must run on a dedicated KVM / bare-metal pool. Three supported paths, all behind
the same port:

| Path | Backend | Where | Notes |
|------|---------|-------|-------|
| **EKS `*.metal` node group** *(primary, EKS)* | E2B / Firecracker | tainted `sandbox=true:NoSchedule` node group — [`deploy/eks/terraform/sandbox.tf`](../eks/terraform/sandbox.tf) | strongest isolation; only sandbox VMs land there |
| **KVM host / DO bare-metal** *(primary, DO)* | E2B [`e2b-dev/infra`](https://github.com/e2b-dev/infra) (Terraform + Nomad + Consul) | a KVM-capable droplet / bare-metal box | run the E2B control plane on the host; app droplet stays as-is |
| **gVisor / Daytona** *(fallback, any node)* | `runsc` (no KVM required) | normal app nodes | `SANDBOX_KIND=daytona`; trades a slice of VM-level separation for running anywhere |
| **E2B Cloud** *(optional, dev/burst)* | managed | vendor | `SANDBOX_KIND=e2b_cloud`; per-sandbox billing, data leaves your infra |

The point of the port: **the isolation backend is a per-environment choice, not an app
change.** Prod EKS/DO run self-hosted (KVM where available, gVisor where not); dev may point
at E2B Cloud — the crawl/convert/code-gen callers are identical across all of them.

## Egress policy

The fleet runs a **default-deny egress proxy**. A sandbox reaches the network only when its
spec opts in:

- `tmpl-crawl` → the **SSRF allowlist** (`https` only, public IPs after full A/AAAA
  resolution, no redirects, bounded size/time — identical to `web_distill`).
- `tmpl-convert` → **none** (offline conversion).
- `tmpl-coderun` → **none** by default; opt-in per-run allowlist, HITL-gated.

A sandbox never holds a provider key and never reaches the DB/Qdrant — code that needs AI or
knowledge calls back out through the LLM Gateway / MCP chokepoints only.

## Warm pool & scaling

- `warm_pool` (per template, in `e2b.toml`) keeps N pre-booted microVMs to hide cold start
  on hot paths (crawl/convert).
- Fleet capacity autoscales on the KVM node group independently of the orchestrator pods
  (Phase 4: KEDA on JetStream lag → orchestrators; fleet autoscaler → microVM capacity).
