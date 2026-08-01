# Contract: Sandbox Runtime (standalone self-hosted tier + per-runtime port)

**Plan**: [../plan.md](../plan.md) | The single chokepoint for **all isolated code / tool execution**. Anything that runs an untrusted browser, an untrusted file parser, or agent-**generated** code runs inside an ephemeral, network-isolated **microVM sandbox** — never on a shared worker pod. Phase 1 runs a **standalone, self-hosted [E2B](https://e2b.dev) cluster** (Firecracker microVMs) — the **only** holder of the sandbox fleet control plane, the template registry, and the egress-proxy policy. Both runtimes reach it through a **thin `Sandbox` port** and make no direct sandbox-vendor SDK calls in business code, exactly as the [LLM Gateway](./llm-gateway.md) is the only chokepoint for LLM access.

> **Why this tier exists.** Three workloads share one property — they execute *attacker-influenceable or model-authored* code and must be contained: **crawl4ai** (drives a headless Chromium over URLs a member may paste or a poisoned search result may return), **MarkItDown** conversion (parses untrusted user files — a real parser-RCE surface), and **future code-gen tools** (an agent writes a script to manipulate files). A microVM boundary (hardware virtualization) is a **strictly stronger** isolation than the shared-pod model the crawl worker used before, and unifying all three onto it replaces N bespoke isolation stories with one. This tier is the generalization of "peel the headless-browser workload off the shared pods" ([README — deployable runtimes](../../../README.md#deployable-runtimes-at-a-glance)) — now hardware-enforced and reused by convert + code-gen.

## Templates (versioned, baked toolchains)

A **template** is a Dockerfile-defined image the fleet boots microVMs from — the exact toolchain per workload, versioned independently. Templates live in [`deploy/sandbox/templates/`](../../../deploy/sandbox/templates/) and are built + published to the self-hosted registry by the sandbox build step.

| Template | Toolchain | Consumer | Egress |
|----------|-----------|----------|--------|
| `tmpl-crawl` | Chromium + Playwright + Crawl4AI | `ingestion.crawl.<ws>` orchestrator (note-enrichment fetch, FR-001) | **SSRF allowlist only** — `https`, public IPs, no redirects (see [mcp-tools.md — web_distill](./mcp-tools.md)) |
| `tmpl-convert` | MarkItDown + LibreOffice / pandoc / parsers | `ingestion.{pdf,docx,image}.<ws>` convert step | **none** (offline conversion; no network) |
| `tmpl-coderun` *(Phase 2)* | Python + Node runtime, no ambient secrets | agent code-gen tool (`run_script` / `transform_files`, [mcp-tools.md Category D](./mcp-tools.md)) | **none by default**; opt-in per-run allowlist, HITL-gated |

> The `tmpl-crawl` toolchain is lifted verbatim from the retired `backend-python/Dockerfile.crawl` (Playwright/Chromium base + the `crawl` dependency group) — the crawl footprint moves *into a microVM template*, off the shared Python pods, with no capability loss.

## Deployment & swappability (self-host primary, managed optional)

- The sandbox tier is a **standalone service** — its own deployment, the **only** holder of the fleet control plane (orchestrator + template registry + egress proxy). Business code never sees a vendor API key.
- **Self-hosted is primary on both DO and EKS** (the user's decision). Managed **E2B Cloud** is an optional swap for dev / burst, behind the same port.
- **Swap by config, no caller change**: `SANDBOX_KIND` (`e2b_selfhost` | `e2b_cloud` | `daytona` | `local_docker`) + `SANDBOX_URL`. The port surface is vendor-neutral, so re-platforming crawl/convert/code-gen across backends is a client-config change, invisible to callers (same seam discipline as `LLM_GATEWAY_KIND`).
- **Hardware constraint (must be provisioned, not assumed).** Firecracker needs `/dev/kvm`. Standard EKS nodes (`t3.large`) and standard DO droplets **do not expose nested virtualization**, so the self-hosted fleet runs on a **dedicated KVM / bare-metal pool**:
  - **EKS** — a tainted `*.metal` managed node group ([`deploy/eks/terraform/sandbox.tf`](../../../deploy/eks/terraform/sandbox.tf)), `sandbox=true:NoSchedule`, so only sandbox VMs land there (blast-radius + right-sizing isolation).
  - **DO** — a bare-metal / KVM-capable pool, or a single KVM host running the E2B [`e2b-dev/infra`](https://github.com/e2b-dev/infra) stack (Terraform + Nomad + Consul).
  - Where KVM is unavailable, `SANDBOX_KIND=daytona` (or a gVisor/`runsc` adapter) sits behind the **same port** — a per-environment isolation choice, not an app change. **This is why the port abstraction is load-bearing.**
- **Tier-0 infra**: on the ingest/crawl/agent critical path; custodies no product data at rest. HA + fleet autoscaling are Phase 4 (see [Scalability](#scalability)).

## Interface

The **Python sandbox-client** (`services/sandbox/client.py`) exposes this port to business code and forwards to the standalone tier; it is also the swap seam (self-host ↔ cloud ↔ Daytona is a client-config change, invisible to callers). Consumers are Python-tier (crawl / ingest / agent), so the port lives in Python — but **every run is policy-gated + metered + audited through the Go-owned control plane**, exactly as MCP tools are (one policy authority, [research §19](../research.md)).

```python
@dataclass
class SandboxSpec:
    template: str              # "tmpl-crawl" | "tmpl-convert" | "tmpl-coderun"
    workspace_id: str
    user_id: str
    feature: str               # "ingest.crawl" | "ingest.convert" | "agent.run_script"
    files_in: list["StagedFile"] = field(default_factory=list)  # S3 refs staged into the VM (scoped)
    egress: "EgressPolicy" = DENY_ALL     # default-deny; crawl passes the SSRF allowlist
    timeout_s: int = 60        # hard wall-clock cap — VM is killed on expiry
    vcpu: int = 1
    mem_mb: int = 1024
    idem_key: str | None = None

@dataclass
class SandboxResult:
    exit_code: int
    stdout: str
    stderr: str
    files_out: list["StagedFile"]         # artifacts written back to a scoped S3 prefix
    vcpu_seconds: int                     # metered
    wall_ms: int
    egress_bytes: int                     # metered
    sandbox_id: str                       # audited (sandbox_run.id)
    timed_out: bool

class Sandbox(Protocol):
    async def run(self, spec: SandboxSpec, *, cmd: list[str] | str) -> SandboxResult: ...
    async def run_code(self, spec: SandboxSpec, *, code: str, lang: str) -> SandboxResult: ...
    # low-level lifecycle (pooling / streaming); business code prefers run/run_code
    async def create(self, spec: SandboxSpec) -> "SandboxHandle": ...
    async def close(self, sandbox_id: str) -> None: ...
```

## Security invariants (release-relevant)

The sandbox tier is a new **enforcement point** governed by the same policy the rest of the system reads. It must not become a hole around the two existing chokepoints.

1. **No ambient credentials, no ambient data.** A sandbox gets **no** provider API keys, **no** DB/Redis/Qdrant connection, **no** cluster credentials. It sees only the files explicitly staged into it. Generated code that needs AI or knowledge must call **back out through the LLM Gateway / MCP PEP** — it can never bypass them (`egress` reaches only those chokepoints, and only when the template allows it).
2. **Egress is default-deny + allowlist proxy.** `EgressPolicy = DENY_ALL` unless the spec opts in. `tmpl-crawl` gets exactly the SSRF allowlist (`https`, public IPs after full A/AAAA resolution, no redirects, bounded size/time — the same rule as [`web_distill`](./mcp-tools.md)); `tmpl-convert` gets none. The microVM network boundary makes this enforceable at the VM, not just in app code.
3. **Access control is preserved (SC-001).** Staged files are scoped by the caller's `workspace_id` / clearance at stage-in; nothing a sandbox produces enters the index directly. Convert/crawl output re-enters through the **existing pipeline** (chunk → embed) and code-gen/write output re-enters through the **HITL accept** gate — so a poisoned page or malicious file can at worst influence a *draft a human reviews*, never widen access.
4. **Metering (SC-006).** Sandbox compute is a first-class spend: `vcpu_seconds`, `wall_ms`, `egress_bytes` are priced by the `Pricer` and emitted as `billing.deduct.<ws>` with `operation_type ∈ {sandbox.crawl, sandbox.convert, sandbox.run_script}`. The **Go kernel billing worker stays the single `credit_ledger` writer** ([metering-ports.md](./metering-ports.md)); the sandbox client only publishes computed spend. "Every AI op metered" now includes "every sandbox-second metered."
5. **HITL for outward / mutating runs (FR-040).** `tmpl-coderun` invoked as the agent `run_script`/`transform_files` tool is a **Category-D action** — off by default per role, gated by the `human_gate` (`approval_request(kind='run_script')`), fail-closed, no-spend-while-paused, running only in the durable long-horizon form ([approval-ports.md](./approval-ports.md)). Internal, non-mutating steps (crawl fetch, convert) need no per-run HITL — they match today's internal crawl fetch.
6. **Hard resource + time caps.** Every spec carries `timeout_s`, `vcpu`, `mem_mb`; the VM is force-killed on expiry (`timed_out=true`) and a killed run spends only the compute it used. No unbounded sandbox.
7. **Audit.** Every run writes one `sandbox_run` row: `id`, `workspace_id`, `user_id`, `template`, `feature`, `exit_code`, `vcpu_seconds`, `egress_bytes`, `timed_out`, `result_hash`, `trace_id` — the sandbox analogue of `agent_audit_log`, joinable by `trace_id`.

## Consumers & seams

| Caller | How it uses the tier | Governance |
|--------|----------------------|------------|
| **crawl orchestrator** (`ingestion.crawl.<ws>`) | Thin role: `Sandbox.run(tmpl-crawl, files_in=[], egress=SSRF_ALLOW, cmd=fetch(url))`; distills result; the browser lives in the VM, not the pod | metered `sandbox.crawl`; internal step, no HITL (FR-001) |
| **convert step** (`ingestion.{pdf,docx,image}.<ws>`) | `Sandbox.run(tmpl-convert, files_in=[s3_key], egress=DENY_ALL)`; returns Markdown; pipeline continues to chunk/embed | metered `sandbox.convert`; internal step, no HITL |
| **agent code-gen tool** *(Phase 2)* | `run_script`/`transform_files` → `Sandbox.run_code(tmpl-coderun, files_in=run.working_set)`; output re-enters via HITL accept | metered `sandbox.run_script`; **HITL-gated**, `allowed_tools` + `can_write` |

The NATS contract is unchanged: `ingestion.crawl.<ws>` still carries `{ doc_id, url, workspace_id, … }` ([nats-subjects.md](./nats-subjects.md)) — only its **consumer** changes from a bespoke Chromium image to a thin orchestrator over this port.

## Scalability

- **Ephemeral, pooled microVMs.** One sandbox per job, torn down after; a spike in tool workloads scales the **sandbox fleet** (microVMs on the KVM/metal pool) **independently of the orchestrator pods** — orchestration concurrency is decoupled from execution compute.
- **Warm pool per template** hides the (~150 ms) Firecracker cold start on hot paths (crawl/convert); pool depth is a per-template config knob.
- **Two-level autoscaling** *(Phase 4)*: KEDA on JetStream consumer lag → orchestrator pods; the E2B fleet / Nomad autoscaler → microVM capacity on the sandbox node group. Slots into the existing [Phase 4 worker-autoscaling story](../../../README.md#-roadmap).
- **Dedicated, isolated node group** — the fleet's own KVM/`*.metal` pool (tainted), same blast-radius + resource-divergence rationale the README gives for peeling out crawl, now generalized.

## Contract test obligations

- A `tmpl-convert` sandbox has **no** network route: an outbound connection attempt from inside fails (egress default-deny).
- A `tmpl-crawl` sandbox rejects a URL resolving to a private/loopback/link-local/reserved IP and rejects non-`https` before any fetch (SSRF parity with `web_distill`).
- A sandbox has **no** provider key and **no** DB/Qdrant reachability: code that tries to read them fails; an AI/knowledge call succeeds only via the LLM Gateway / MCP chokepoint.
- A run exceeding `timeout_s` is killed with `timed_out=true` and spends only used compute; no run exceeds its `vcpu`/`mem_mb` cap.
- A completed run emits exactly one `billing.deduct.<ws>` (`operation_type=sandbox.*`) → the **Go** billing worker inserts exactly one `credit_ledger` row (idempotent on `idem_key`); Python never writes the ledger (SC-006).
- Every run writes exactly one `sandbox_run` row with a `result_hash` and `trace_id`.
- The `run_script` code-gen tool (Category D) opens `approval_request(kind='run_script')` and **executes nothing** until the member approves; a rejected run mutates no files and spends nothing (FR-040, FR-041).
- Swapping `SANDBOX_KIND` (`e2b_selfhost` ↔ `daytona` ↔ `local_docker`) changes no caller code — the same crawl/convert contract tests pass across backends.
