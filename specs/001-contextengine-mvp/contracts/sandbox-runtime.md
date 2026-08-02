# Contract: Sandbox Runtime (isolated-execution tier + per-runtime port)

**Plan**: [../plan.md](../plan.md) | The single chokepoint for **all isolated code / tool execution**. Anything that runs an untrusted browser, an untrusted file parser, or agent-**generated** code runs inside an ephemeral, **credential-free, egress-locked sandbox** — never in the orchestrator process, never with ambient credentials, never able to reach the DB, Qdrant, or a provider key. Both runtimes reach the tier through a **thin `Sandbox` port** and make no direct sandbox-vendor SDK calls in business code, exactly as the [LLM Gateway](./llm-gateway.md) is the only chokepoint for LLM access.

**Phase 1 runs the cheapest boundary that carries those invariants: a hardened container, no microVM** — no new infrastructure, no standing cost. Which *kind* implements it is per-environment (`docker` on local macOS and the first DO-droplet deploy; `k8s_pod` on k3s/EKS) — see [Deployment](#deployment--swappability-pod-primary-microvm-opt-in). Stronger boundaries (gVisor `runsc`; self-hosted [E2B](https://e2b.dev)/Firecracker microVMs) are the **same contract behind the same port**, selected per environment by `SANDBOX_KIND`. **The isolation strength is a deployment dial; the security contract is not.**

> **Why this tier exists.** Three workloads share one property — they execute *attacker-influenceable or model-authored* code and must be contained: **crawl4ai** (drives a headless Chromium over URLs a member may paste or a poisoned search result may return), **MarkItDown** conversion (parses untrusted user files — a real parser-RCE surface), and **future code-gen tools** (an agent writes a script to manipulate files). Unifying all three behind one port replaces N bespoke isolation stories with one, and makes the boundary strength a per-workload, per-environment choice rather than an architectural commitment. This tier is the generalization of "peel the headless-browser workload off the shared pods" ([README — deployable runtimes](../../../README.md#deployable-runtimes-at-a-glance)) — now reused by convert + code-gen.

> **Why not microVMs in Phase 1.** Firecracker requires `/dev/kvm`, which on AWS means a `*.metal` node group — a **standing cost on the order of $3k/month** for the smallest x86 metal SKU. The Phase-1 crawl workload is member-initiated note enrichment (FR-001): low-volume, one-shot, `https`-only public pages, with a **human accept gate before anything is indexed**. Buying a hardware boundary for that is disproportionate — the residual risk it closes is a Chrome-renderer RCE chained with a kernel LPE, landing the attacker on a **credential-free pod with default-deny egress on a tainted node**. The metal path stays fully specified and one config flag away ([`sandbox_enabled`](../../../deploy/eks/terraform/variables.tf)); it is bought when `tmpl-coderun` ships, not before. Rejected alternatives and the full cost comparison are in [research §24](../research.md).

## Templates (versioned, baked toolchains)

A **template** is a Dockerfile-defined image the tier runs a sandbox from — the exact toolchain per workload, versioned independently. Templates live in [`deploy/sandbox/templates/`](../../../deploy/sandbox/templates/). The **same Dockerfile** is the container image under `docker`/`k8s_pod` (at either `SANDBOX_RUNTIME`) and the microVM rootfs under `e2b_selfhost` — swapping the backend does not rebuild the toolchain.

| Template | Toolchain | Consumer | Egress | Phase-1 isolation |
|----------|-----------|----------|--------|-------------------|
| `tmpl-crawl` | Chromium + Playwright + Crawl4AI | `ingestion.crawl.<ws>` orchestrator (note-enrichment fetch, FR-001) | **SSRF allowlist only** — `https`, public IPs, no redirects (see [mcp-tools.md — web_distill](./mcp-tools.md)) | hardened pod (Chrome keeps its own multi-process sandbox) |
| `tmpl-convert` | MarkItDown + LibreOffice / pandoc / parsers | `ingestion.{pdf,docx,image}.<ws>` convert step | **none** (offline conversion; no network) | hardened pod; **gVisor when this path ships** — see the ratchet below |
| `tmpl-coderun` *(Phase 2)* | Python + Node runtime, no ambient secrets | agent code-gen tool (`run_script` / `transform_files`, [mcp-tools.md Category D](./mcp-tools.md)) | **none by default**; opt-in per-run allowlist, HITL-gated | **microVM** — the workload that justifies buying `/dev/kvm` |

> The `tmpl-crawl` toolchain is lifted verbatim from the retired `backend-python/Dockerfile.crawl` (Playwright/Chromium base + the `crawl` dependency group) — the crawl footprint moves *into a sandbox template*, off the shared Python pods, with no capability loss.

### The isolation ratchet (per workload, not per architecture)

Boundary strength is bought where the risk actually is, not uniformly:

| Workload | Risk profile | Boundary | Set via | Why |
|----------|--------------|----------|---------|-----|
| `tmpl-crawl` | Public `https` pages; Chromium has its own sandbox; HITL accept before indexing | hardened container, shared kernel | `runtime: runc` | Escape requires a renderer 0-day **plus** a kernel LPE, for a credential-free sandbox. Disproportionate to harden further at MVP volume — and Chromium is the worst case under gVisor (syscall-heavy; needs `--no-sandbox`). |
| `tmpl-convert` | Untrusted **user-uploaded** files through LibreOffice / pandoc / parsers — worse CVE history than Chrome, and **no internal sandbox of its own** | **gVisor** when the path ships | `runtime: runsc` | The genuinely higher-risk surface. Needs no `/dev/kvm`, so it runs on the existing host/node at no infra cost. |
| `tmpl-coderun` | **Model-authored code** — but *your* model's, HITL-approved, over that workspace's own staged files | **gVisor + never reused** (Phase 2) | `runtime: runsc` + `max_runs = 1` | gVisor's designed purpose *is* untrusted code — Google runs multi-tenant customer code on it (Cloud Run, App Engine, GKE Sandbox). A microVM is **stronger, not required**: buy it only if the threat model changes (third-party-authored code, hostile tenants, a compliance rule naming hardware isolation). |

> **On "shared kernel".** gVisor is not a shared kernel in the naive sense: the Sentry services guest syscalls in userspace and is itself seccomp-confined against the host, so an escape needs a Sentry bug *and* to defeat that confinement. Its weakness is *performance* on syscall-heavy workloads — which is exactly why `tmpl-crawl` stays on `runc` (Chromium is the pathological case) while a Python file-transform script, which is not, sits comfortably on it. Cold start also runs **opposite** to isolation strength here: Firecracker boots in ~150–250 ms, faster than a cold Kubernetes pod.
>
> The `Set via` column is the reason `SANDBOX_RUNTIME` is **per-template overridable** rather than a single global value — see [the two axes](#two-independent-axes--orchestration-and-runtime). A global setting cannot express "convert on gVisor, crawl on `runc`", which is exactly what this table asks for.

**What a weaker boundary does and does not cost.** Of the twelve [security invariants](#security-invariants-release-relevant), **eleven are enforced by the port, the policy plane, and the Go control plane — not by the hypervisor**, and hold identically in a pod: no ambient credentials (1), access control preserved (3), metering (4), HITL (5), hard resource caps (6), audit (7), no runtime socket (8), versioned write-back (9), no bind mounts (10), allowlisted create-args (11), stateless-per-job (12). Only invariant 2's *enforcement point* moves — from a VM network boundary to a `NetworkPolicy` at the CNI plus the allowlist proxy. The single property genuinely surrendered in Phase 1 is **kernel-escape resistance**, and only for crawl and convert.

> **The weak boundary is not the dangerous part — the control plane is.** A pod boundary that a renderer 0-day plus a kernel LPE might cross is a bounded risk. A sandbox orchestrator holding a host container-runtime socket, or interpolating config- or model-derived values into container-create arguments, is an *unbounded* one: it hands out host-equivalent privilege directly, with no exploit chain required. Invariants **8–12** exist because that failure mode has repeatedly sunk otherwise-careful agent sandboxes, and it is orthogonal to how strong the boundary is — a Firecracker fleet driven by an over-privileged control plane is no safer than a pod.

## Deployment & swappability (pod primary, microVM opt-in)

- The sandbox tier is a **standalone deployment** — the only holder of the template registry and the egress-proxy policy. Business code never sees a vendor API key.
- **The Phase-1 boundary is "hardened container, no microVM" — but the kind that implements it is per-environment**, because the deploy targets differ in topology. DO Phase 1 is **docker-compose on a single droplet** ([`docker-compose.prod.yml`](../../../deploy/do/docker-compose.prod.yml)); there is no Kubernetes API there, so `k8s_pod` is not available and `SANDBOX_KIND=docker` is the DO backend until either k3s or EKS lands.

| Environment | `SANDBOX_KIND` | `SANDBOX_RUNTIME` | Note |
|-------------|----------------|-------------------|------|
| **Local (macOS)** | `docker` | `runc` (forced) | gVisor is a **Linux** syscall implementation and Docker Desktop's VM ships only `runc`/`io.containerd.runc.v2`. `runsc` is not installable here. |
| **DO droplet (Phase 1, first deploy)** | **`service`** | `runc` → **`runsc` recommended** | Long-lived compose services, **no runtime socket anywhere**. The droplet is Linux, so gVisor is a one-flag change (`--runtime=runsc`), not a re-platform. |
| **EKS** | `k8s_pod` | `runc`, `runsc` per template | Per-job pods via RBAC — strictly less privilege than a socket, and per-job costs nothing extra here, so the full recycle guarantee returns. |
| **EKS — `tmpl-coderun`** | `k8s_pod` | **`runsc`** | gVisor is the **default** for model-authored code (see the ratchet). No metal, no `/dev/kvm`, $0. |
| **Only if the threat model changes** | `e2b_selfhost` | n/a (microVM) | Third-party-authored code, hostile tenants, or a compliance rule naming hardware isolation. **Not otherwise required.** |

> **Why DO uses `service` rather than `docker`.** Per-job isolation is worth buying **exactly when it does not cost a runtime socket.** On compose, anything per-job must create containers, which means mounting a host runtime socket — *host-equivalent, unbounded* privilege held near untrusted input. Paying that to close a *bounded* tenant-persistence risk is a bad trade at MVP volume, so DO runs long-lived `service` sandboxes and **mounts no socket at all**. On Kubernetes the calculus inverts: per-job costs only an RBAC-scoped ServiceAccount, so `k8s_pod` takes per-job and gets the full recycle guarantee back. **The lifecycle follows the deployment's privilege economics, not the workload.** `SANDBOX_KIND=docker` remains available for local macOS dev, where invariant 8's confinement rule applies (socket to the sandbox executor alone — never `go-api`, `go-relay`, `go-worker`, `py-api`, `py-worker`, `py-mcp`, `llm-gateway`, or `crawl`).


### Two independent axes — orchestration and runtime

**`SANDBOX_KIND` and the isolation runtime are orthogonal, and conflating them is a category error.** gVisor is not a place to run sandboxes; it is a **runtime flag on the orchestration you already have** (`--runtime=runsc` under Docker, `runtimeClassName: gvisor` under Kubernetes). Daytona, by contrast, is a *product* with its own control plane — a peer of E2B, not of gVisor. Earlier revisions of this contract listed `daytona` as the "gVisor kind", which made two things impossible:

1. **The per-workload ratchet could not be expressed.** `SANDBOX_KIND` is one global value, so "`tmpl-convert` on gVisor, `tmpl-crawl` on `runc`" — the whole point of the ratchet above — had no representation.
2. **A one-flag runtime change looked like a re-platform.** Turning on gVisor reads as "adopt Daytona," which is a far larger and entirely unnecessary commitment.

So the tier takes **two** settings:

- **`SANDBOX_KIND`** — *how sandboxes are orchestrated*: `service` | `oneshot` | `k8s_pod` | `docker` | `e2b_selfhost` | `e2b_cloud`, plus `SANDBOX_URL`. This also fixes the **lifecycle** (long-lived pool vs. per job) — see invariant 12.
- **`SANDBOX_RUNTIME`** — *what isolates them*: `runc` (default) | `runsc` (gVisor). **Per-template overridable**, which is what makes the ratchet implementable; ignored under the `e2b_*` kinds, where the microVM is the boundary.

| `SANDBOX_KIND` | Orchestration | Lifecycle | Where it runs | Cost | Status |
|----------------|---------------|-----------|---------------|------|--------|
| **`service`** | Long-lived pool reached over HTTP. **Creates nothing at runtime → no socket, ever** | **stateless per job**, recycled on a bound (inv. 12) | compose / any host | **$0** | **DO Phase 1** |
| **`oneshot`** | N declared replicas, each pulling **exactly one** job from a NATS queue group then **exiting**; the restart policy recreates it. **Creates nothing → no socket** | **per job, real destruction** — the process dies | compose / any host | **$0** | **DO path for `tmpl-coderun`** |
| **`k8s_pod`** | Per-job Pod via **RBAC-scoped ServiceAccount**, no socket | **per job**, full workspace recycle | existing app node pool | **$0** | **preferred posture — needs k3s/EKS** |
| `docker` | Sibling container. **Requires a runtime socket** (inv. 8 — confine to the executor) | per job | laptop | $0 | **local macOS dev only** |
| `e2b_selfhost` | Firecracker microVM fleet | per job | tainted KVM/`*.metal` pool ([`sandbox.tf`](../../../deploy/eks/terraform/sandbox.tf)) | **~$3k/mo** on AWS `*.metal`; ~$50–100/mo third-party | **not required** — only if the threat model changes |
| `e2b_cloud` | Managed Firecracker | per job | vendor | usage-billed | dev / burst; **user files leave your infra under `tmpl-convert`** |

| `SANDBOX_RUNTIME` | Boundary | Requires | Cost |
|-------------------|----------|----------|------|
| **`runc`** (default) | Namespaces + cgroups + seccomp — shared kernel | nothing | $0 |
| **`runsc`** (gVisor) | User-space kernel — a real syscall boundary | **Linux** + `runsc` installed on the host/node | $0 infra, one runtime install |

> **A candidate backend worth evaluating, not yet adopted.** [OpenSandbox](https://github.com/opensandbox-group/OpenSandbox) (Apache-2.0, ~12.3k stars, active) ships gVisor/Kata/Firecracker across Docker **and** Kubernetes runtimes — a productized form of the ratchet above, and it would cover the still-unbuilt `k8s_pod` path. It would enter as `SANDBOX_KIND=opensandbox` behind this same port, replacing only the *mechanical* half: invariants 3, 4, 5, 7, 9 and 12 are domain obligations that stay in the port and the Go control plane whatever executes the container. Four blocking questions before adoption — socket posture, `max_runs = 1` support, default-deny egress, and RBAC narrowness — are recorded in [research §24](../research.md).

> **Daytona is not adopted.** It is a legitimate vendor alternative to E2B if a managed sandbox control plane is ever wanted, but it is *not* how gVisor is enabled and is not in the enum. If it is adopted later it enters as a `SANDBOX_KIND`, alongside `e2b_*`.

- **Swap by config, no caller change.** The port surface is vendor-neutral on both axes, so re-platforming crawl/convert/code-gen is a client-config change, invisible to callers (same seam discipline as `LLM_GATEWAY_KIND`). **This is the load-bearing property of the design** — it is what lets Phase 1 ship on the cheap boundary without foreclosing the strong one.

- **Pod hardening is mandatory under `k8s_pod`**, and is what makes the default defensible: `runAsNonRoot`, `readOnlyRootFilesystem`, `capabilities: {drop: [ALL]}`, `seccompProfile: RuntimeDefault`, no service-account token mounted, resource `limits` matching the spec's `vcpu`/`mem_mb`, and a `NetworkPolicy` with default-deny egress (crawl's allowlist is granted only via the proxy). A sandbox pod that is not hardened is a contract violation, not a configuration preference.
- **The microVM path stays fully specified and one flag away.** `sandbox_enabled=true` provisions the tainted `*.metal` node group; on DO, a KVM-capable host runs the E2B [`e2b-dev/infra`](https://github.com/e2b-dev/infra) stack. Nothing in the app changes. **Bare metal need not mean AWS bare metal** — third-party bare metal (Hetzner/OVH) runs the same Firecracker fleet at roughly 1/40th the AWS `*.metal` price, at the cost of an off-cluster network path.
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
    stdout: str                # TRUNCATED at the template's stdout_max_bytes (256 KiB for
                               # tmpl-coderun). Unbounded stdout flows straight into agent
                               # context: an analysis script printing a dataframe emits
                               # megabytes of billable tokens. Bulk output goes to files_out.
    stdout_truncated: bool     # true when the cap was hit — the agent must be able to tell
                               # a short result from a silently clipped one
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

The sandbox tier is a new **enforcement point** governed by the same policy the rest of the system reads. It must not become a hole around the two existing chokepoints. **All twelve invariants below are obligations of the tier, not of a particular backend** — they hold identically under `docker`, `k8s_pod`, and `e2b_selfhost`, at either `SANDBOX_RUNTIME`, and the [contract tests](#contract-test-obligations) run unchanged across all of them.

1. **No ambient credentials, no ambient data.** A sandbox gets **no** provider API keys, **no** DB/Redis/Qdrant connection, **no** cluster credentials. It sees only the files explicitly staged into it. Generated code that needs AI or knowledge must call **back out through the LLM Gateway / MCP PEP** — it can never bypass them (`egress` reaches only those chokepoints, and only when the template allows it).
2. **Egress is default-deny + allowlist proxy.** `EgressPolicy = DENY_ALL` unless the spec opts in. `tmpl-crawl` gets exactly the SSRF allowlist (`https`, public IPs after full A/AAAA resolution, no redirects, bounded size/time — the same rule as [`web_distill`](./mcp-tools.md)); `tmpl-convert` gets none. Enforcement is **outside the sandboxed process** at every backend — a `NetworkPolicy` at the CNI plus the allowlist proxy under `k8s_pod`, a user-defined network plus the proxy under `docker`, the VM network boundary under `e2b_selfhost` — never merely an in-code guard.
3. **Access control is preserved (SC-001).** Staged files are scoped by the caller's `workspace_id` / clearance at stage-in; nothing a sandbox produces enters the index directly. Convert/crawl output re-enters through the **existing pipeline** (chunk → embed) and code-gen/write output re-enters through the **HITL accept** gate — so a poisoned page or malicious file can at worst influence a *draft a human reviews*, never widen access.
4. **Metering (SC-006).** Sandbox compute is a first-class spend: `vcpu_seconds`, `wall_ms`, `egress_bytes` are priced by the `Pricer` and emitted as `billing.deduct.<ws>` with `operation_type ∈ {sandbox.crawl, sandbox.convert, sandbox.run_script}`. The **Go kernel billing worker stays the single `credit_ledger` writer** ([metering-ports.md](./metering-ports.md)); the sandbox client only publishes computed spend. "Every AI op metered" now includes "every sandbox-second metered."
5. **HITL for outward / mutating runs (FR-040) — gated on *what the run does*, not on which template it uses.** FR-040 gates actions that (a) mutate the knowledge index, (b) apply a model-suggested security attribute above the uploader default, or (c) reach outside the workspace. Applying that test to `tmpl-coderun` splits it in two:
   - **`transform_files` — always gated.** It writes. `approval_request(kind='run_script')`, fail-closed, no-spend-while-paused, durable long-horizon form only ([approval-ports.md](./approval-ports.md)), and output re-enters the index only through the accept gate.
   - **`run_script` in *read-only analysis* form — gated per session, not per run.** A run with `files_out = []`, `egress = DENY_ALL`, and a read-only working set is pure computation over files the actor was **already** authorised to read (invariant 3), so it satisfies **none** of FR-040's three criteria. Requiring approval for each attempt would gate it more strictly than the requirement it cites — and punishingly, since code agents iterate: write → run → read the traceback → fix → re-run, which at per-run approval means three sandboxes and **three human approvals** for one answer. The member approves the *analysis session*; each attempt inside it runs unattended. **The moment a run requests `files_out`, egress, or a write, it is a `transform_files` action and the per-run gate applies** — the read-only form must be structurally unable to escalate itself.
   - Internal, non-mutating steps (crawl fetch, convert) need no per-run HITL — they match today's internal crawl fetch.
6. **Hard resource + time caps, including PIDs.** Every spec carries `timeout_s`, `vcpu`, `mem_mb`, and a **process-count cap**; the sandbox is force-killed on expiry (`timed_out=true`) and a killed run spends only the compute it used. Under `k8s_pod` CPU/memory map to pod `resources.limits`, wall-clock to an orchestrator-side kill, and the PID cap to the kubelet's **`podPidsLimit`** — a *node-level* setting, so it must be configured on the sandbox node pool rather than assumed from the pod spec. Under `docker` it is `--pids-limit`; under `e2b_selfhost`, the VM's own caps. **A memory and CPU cap without a PID cap is not a cap** — a fork bomb in a parser or a headless browser exhausts the node's process table long before it hits `mem_mb`. No unbounded sandbox.
7. **Audit.** Every run writes one `sandbox_run` row: `id`, `workspace_id`, `user_id`, `template`, `feature`, `exit_code`, `vcpu_seconds`, `egress_bytes`, `timed_out`, `result_hash`, `trace_id` — the sandbox analogue of `agent_audit_log`, joinable by `trace_id`.
8. **No component ever holds a host container-runtime socket.** Mounting `/var/run/docker.sock` (or a containerd/CRI socket) grants **host-equivalent privilege** — the holder can create a privileged container with `/` bind-mounted, so containerizing it buys nothing. A `:ro` mount does **not** mitigate this: read-only applies to the socket *file*, not to the API, and `POST /containers/create` still works. Therefore:
   - Under **`k8s_pod`** (the preferred posture, at either runtime) the orchestrator creates sandboxes through the **Kubernetes API using an RBAC-scoped ServiceAccount** restricted to `create`/`get`/`delete` on `pods` **in the sandbox namespace only** — no `exec`, no `privileged`, no cluster-wide verbs, no node access. This is strictly less privilege than a socket and is the reason the K8s path is primary.
   - The **`docker` kind is single-host dev/compose only** and is **never** the EKS posture. Where it is used, the socket is held by the sandbox executor process **alone** — never by the BFF, the LLM gateway, the MCP server, or any worker that touches channel input or model output. The components chewing on untrusted input must be the ones furthest from the socket.
9. **`files_out` write-back is in-place versioning, and the approver must see the *bytes*, not the model's account of them (Phase 2).** An approved `transform_files` run replaces the document's current content and retains the prior bytes as `document_versions` ([data-model.md](../data-model.md)). Two obligations govern the gate:
   - **The approval payload is derived from the artifact, never from the model.** FR-040 requires the human decision to originate from the approver and **not** be derived from model, tool, or document output — so an approver shown only "the agent says it updated the Q3 totals" is approving a *claim*, not a change. The gate MUST present: (a) the generated script source, (b) a **rendered diff** — both the current and candidate bytes converted through the existing `tmpl-convert` path to Markdown, then diffed — and (c) a structured summary computed from the two artifacts (sheets touched, rows/cells changed). All three come from bytes the tier holds; none is the model's narration.
   - **Binary opacity is the reason this gate is stricter than `edit_note`'s.** A note diff is human-readable as-is; an `.xlsx` is not, so without a rendered diff the HITL gate degrades into a rubber stamp — the member clicks approve on something they cannot inspect. Reusing `tmpl-convert` for the rendering costs no new infrastructure and keeps the untrusted parse inside a sandbox.
10. **No bind mounts, ever.** Files enter a sandbox **only** as `files_in` staged from S3 (invariant 3) and leave only as `files_out` to a scoped prefix. No host path is ever mounted into a sandbox. This is not merely hardening — it **structurally eliminates** two bug classes at once: mount-argument injection (nothing can inject a `-v` that does not exist), and the sibling-container host-path trap (a container-created sibling resolves bind sources against the *host* filesystem, not the caller's, which fails silently in one direction and exposes an unintended host path in the other).
11. **Create-arguments come from a fixed allowlist, never from interpolation.** The pod/container spec is constructed from a **closed schema** of fields the tier owns (image ref from the template registry, command, `resources.limits`, `securityContext`, `NetworkPolicy` selector). **No config-, request-, or model-derived value may reach** mounts, network mode, `hostNetwork`/`hostPID`/`hostIPC`, capabilities, `securityContext`, `runtimeClassName`, `privileged`, or seccomp/AppArmor profile. Values that vary per run (`vcpu`, `mem_mb`, `timeout_s`, `template`) are validated against typed bounds and an enumerated template list **before** spec construction, and an unknown `template` is rejected rather than passed through. Unvalidated config → container-create is a recurring container-escape vector; the enforcement must be at spec-build time, not in documentation.
12. **Stateless per job, recycled on a bound — two distinct obligations.** *Statelessness* kills **data** carryover: every job gets a fresh execution context (a new `browser.newContext()` for crawl, a fresh subprocess + a fresh temp dir for convert), so no cookies, storage, cached page content, or scratch files survive into the next job. *Recycling* kills **compromise** carryover: a fresh context does **not** evict an attacker already resident in the process, so an instance is destroyed after `max_runs_per_sandbox` and a wall-clock TTL. **Conflating the two is how a warm pool silently becomes the weak link.** Under the per-job kinds (`k8s_pod`, `docker`, `e2b_*`) both come free — the instance dies with the job — and the workspace boundary is a *hard* container boundary. Under **`service` the workspace boundary is soft**: statelessness is enforced in-process, and compromise persistence is *bounded* by recycle rather than eliminated. That is the accepted, documented delta of the DO posture — and the reason `tmpl-coderun` is **never** served from a `service` pool.
    - **Deployment consequence:** `tmpl-coderun` **cannot run under `service`** — a long-lived pool means reuse, which is the one thing `max_runs = 1` exists to prevent. It needs a kind that genuinely destroys the instance. On Kubernetes that is `k8s_pod`. On plain compose it is **`oneshot`** (below), which reaches the same guarantee without a runtime socket. Note the blocker is **not** gVisor — a droplet is Linux and `runsc` runs there fine; it is needing `max_runs = 1` **and** socket-freedom *simultaneously*. Do **not** reach for `SANDBOX_KIND=docker` to unblock it: that grants host-equivalent privilege for the single workload least suited to a soft boundary.

### The `oneshot` kind — per-job destruction without a socket

Each replica **starts → pulls exactly one job from a NATS queue group → processes it → exits**; the container runtime's restart policy recreates it with a fresh tmpfs over immutable image layers. N replicas give N-way concurrency. The queue group **is** the claim protocol, so the [pool-lease obligations](#scalability--latency) do not apply — a replica claims its own work and there is no pool bookkeeping to get wrong.

**`service` with `max_runs = 1` is NOT equivalent and must not be substituted.** Under `service` the process survives and *resets*; under `oneshot` the process *dies*. Resetting clears data; it does not evict a resident attacker (invariant 11). The whole value of `oneshot` is that destruction is real.

Three obligations, all of which **fail silently** — they are contract-tested, not configured:

1. **`read_only: true`, with tmpfs as the only writable path.** Load-bearing: a restart reuses the same container ID *and its writable layer*, so a writable rootfs lets a dropped file survive the restart and silently rebuilds the reuse you were avoiding. Invariant 9 (no bind mounts, no volumes) closes the other hole.
2. **The process must exit after one job.** A `while True` around the handler is the failure mode wearing the fix's clothes.
3. **Untrusted code must not inherit the job-transport network.** The replica needs NATS reachability to pull work, but `tmpl-coderun`'s egress policy is `deny` — so a thin **supervisor** (PID 1) holds the NATS connection and forks the model-authored code into a child with **no network namespace**, capturing its result. The untrusted code never sees the bus. **This is `oneshot`'s weakest point relative to `k8s_pod`**, where the job arrives via the API server and the sandbox needs no bus route at all: if the child's network cannot be dropped, the message bus becomes reachable from untrusted code, and `k8s_pod` should be preferred.

Restart-policy backoff is not a problem *for `tmpl-coderun` specifically*, because it is rare and HITL-gated — a replica idles (uptime accumulating, backoff resetting) far longer than it runs. A high-rate template under `oneshot` would thrash, which is another reason this kind is scoped to code-gen.

## Consumers & seams

| Caller | How it uses the tier | Governance |
|--------|----------------------|------------|
| **crawl orchestrator** (`ingestion.crawl.<ws>`) | Thin role: `Sandbox.run(tmpl-crawl, files_in=[], egress=SSRF_ALLOW, cmd=fetch(url))`; distills result; the browser lives in the sandbox, not the orchestrator | metered `sandbox.crawl`; internal step, no HITL (FR-001) |
| **convert step** (`ingestion.{pdf,docx,image}.<ws>`) | `Sandbox.run(tmpl-convert, files_in=[s3_key], egress=DENY_ALL)`; returns Markdown; pipeline continues to chunk/embed | metered `sandbox.convert`; internal step, no HITL |
| **agent code-gen tool** *(Phase 2)* | `run_script`/`transform_files` → `Sandbox.run_code(tmpl-coderun, files_in=run.working_set)`. Envelope is sized for **data analysis** (2 vCPU · 4 GB · 300 s), not a short script; `stdout` truncated at `stdout_max_bytes`; the installed toolkit is a **tool contract** (egress deny ⇒ no runtime `pip install`) | metered `sandbox.run_script`; `allowed_tools` + `can_write`. **HITL per run for `transform_files` (it writes); per *session* for read-only `run_script`** — invariant 5 |

The NATS contract is unchanged: `ingestion.crawl.<ws>` still carries `{ doc_id, url, workspace_id, … }` ([nats-subjects.md](./nats-subjects.md)) — only its **consumer** changes from a bespoke Chromium image to a thin orchestrator over this port.

## Scalability & latency

- **Ephemeral sandbox per job**, torn down after; a spike in tool workloads scales the **sandbox pool independently of the orchestrator pods** — orchestration concurrency is decoupled from execution compute. Under `k8s_pod` the pool is a sandbox `Deployment` on the app node pool; under `e2b_selfhost` it is the microVM fleet on the KVM pool.
- **Cold-start relief is bought in a fixed order — cheapest and safest first.** A cold Kubernetes pod (schedule → image pull → container start) is **seconds**, materially *worse* than a Firecracker boot. But the two dominant terms are *pull* and *scheduling*, and both have fixes that carry **no freshness state**. Exhaust those before building a pod pool:

  1. **Pre-pull images onto sandbox nodes** (a DaemonSet warmer, or a pinned `@sha256` digest with `imagePullPolicy: IfNotPresent`). **This is the single biggest win** — an uncached pull turns ~2 s into 30 s+, and no pool rescues that.
  2. **Reserve scheduling headroom** with a negative-priority `PriorityClass` placeholder pod holding node capacity. A real sandbox pod preempts it instantly, so scheduling latency disappears **without tracking which pods are fresh**.
  3. **Measure.** Steps 1–2 typically land ~1–2 s. Against a crawl path that already spends seconds on page fetch plus LLM distill, that is usually enough — and if it is, **you never build a pool and never own its failure modes.**
  4. **Only then** add a pooled claim, and only for `tmpl-crawl` / `tmpl-convert`.

- **A pod pool is a lease protocol, and a bug in it silently degrades `max_runs = 1` into `max_runs = N`.** If one is built, these four are obligations, not implementation detail:
  1. **Atomic claim** — two concurrent jobs must never receive the same instance. A real lease (Redis `SET NX`, or a k8s `Lease`), never "pick the first `Ready` one."
  2. **Claimed never returns** — an instance leaves the pool at *claim* time, not at completion.
  3. **Failure paths destroy, never return.** An errored, timed-out, or killed run's instance is destroyed. **This is the one that is usually wrong** — the happy path is easy; the failure path is where a used instance sneaks back into the pool.
  4. **Pool members are provably pristine** — created and never job'd, assertable rather than assumed.

  All four are silent in normal operation, which is why they are [contract-tested](#contract-test-obligations) rather than reviewed.

- **`tmpl-coderun` is never pooled** (`pooled = false`, `max_runs = 1`). It is HITL-gated, so a human has just clicked approve and the cold start is imperceptible — paying idle capacity *and* a claim protocol for invisible latency, on the template least tolerant of a bookkeeping bug, is a bad trade in both directions.

- **Pooling trades back part of what per-job bought.** The `k8s_pod` kind's advantage over `service` is the *hard* workspace boundary; a pool re-introduces reuse and softens it. If warmth is what you want on the ingest templates, `SANDBOX_KIND=service` gives it with no claim protocol at all — so choose deliberately rather than pooling `k8s_pod` by reflex.
- **Recycle policy is the isolation dial for the pod backend.** A warm sandbox is reused for at most `max_runs_per_sandbox` jobs and is **always** recycled at a workspace boundary — never reused across workspaces (SC-001). Setting it to 1 restores strict per-run isolation at the cost of warmth; the default trades a bounded amount of reuse for latency.
- **Cold start is not the dominant cost on the crawl path.** Chromium launch (~hundreds of ms) plus page navigation (~1–5 s) plus the downstream distill call set the latency floor; sandbox startup is a minority term at every backend. The FR-001 crawl path is member-initiated and HITL-gated, so it is throughput-light and latency-tolerant by construction — which is precisely why the cheap boundary is adequate here.
- **Two-level autoscaling** *(Phase 4)*: KEDA on JetStream consumer lag → orchestrator pods; a second scaler → sandbox capacity (pod replicas under `k8s_pod`; the E2B fleet / Nomad autoscaler under `e2b_selfhost`). Slots into the existing [Phase 4 worker-autoscaling story](../../../README.md#-roadmap).
- **Node placement.** Under `k8s_pod` the sandbox pool is labelled and (optionally) tainted on the existing node pool — same blast-radius rationale the README gives for peeling out crawl, without a second node group. `e2b_selfhost` adds the dedicated KVM/`*.metal` pool when Phase 2 provisions it.

## Contract test obligations

- A `tmpl-convert` sandbox has **no** network route: an outbound connection attempt from inside fails (egress default-deny).
- A `tmpl-crawl` sandbox rejects a URL resolving to a private/loopback/link-local/reserved IP and rejects non-`https` before any fetch (SSRF parity with `web_distill`).
- A sandbox has **no** provider key and **no** DB/Qdrant reachability: code that tries to read them fails; an AI/knowledge call succeeds only via the LLM Gateway / MCP chokepoint.
- A run exceeding `timeout_s` is killed with `timed_out=true` and spends only used compute; no run exceeds its `vcpu`/`mem_mb` cap. A **fork bomb inside a sandbox is contained by the PID cap** and does not degrade the node — asserted per backend, since the cap lives in a different place in each (`podPidsLimit` on the node pool, `--pids-limit` under `docker`).
- A completed run emits exactly one `billing.deduct.<ws>` (`operation_type=sandbox.*`) → the **Go** billing worker inserts exactly one `credit_ledger` row (idempotent on `idem_key`); Python never writes the ledger (SC-006).
- Every run writes exactly one `sandbox_run` row with a `result_hash` and `trace_id`.
- The `run_script` code-gen tool (Category D) opens `approval_request(kind='run_script')` and **executes nothing** until the member approves; a rejected run mutates no files and spends nothing (FR-040, FR-041).
- Swapping `SANDBOX_KIND` (`docker` ↔ `k8s_pod` ↔ `e2b_selfhost`) **or** `SANDBOX_RUNTIME` (`runc` ↔ `runsc`) changes no caller code — **the same crawl/convert contract tests pass unchanged across every backend**. This test is what makes the Phase-1 → Phase-2 isolation upgrade a config change rather than a migration.
- **Pod-hardening (`k8s_pod`)**: a sandbox pod runs as non-root with a read-only root filesystem, all capabilities dropped, `seccompProfile: RuntimeDefault`, and **no service-account token mounted** — a run that would be scheduled without these fails closed rather than running unhardened.
- **Recycle boundary (`k8s_pod`)**: a warm sandbox is never handed a job from a different `workspace_id` than its previous run, and is destroyed after `max_runs_per_sandbox` (SC-001).
- **No runtime socket (invariant 8)**: no deployment manifest mounts `/var/run/docker.sock` or a CRI socket into the BFF, gateway, MCP server, or any worker — asserted statically over the rendered manifests, so a regression fails CI rather than review. The sandbox ServiceAccount's RBAC grants only `create`/`get`/`delete` on `pods` in the sandbox namespace: `exec`, `privileged`, node access, and cluster-scoped verbs are absent, and a request using them is denied by the API server.
- **No bind mounts (invariant 10)**: a built sandbox spec contains **zero** host-path volumes for every template; the only file paths present are the S3-staged `files_in`/`files_out` locations.
- **Pool claim (only if a pool is built)**: concurrent claims never yield the same instance (asserted under contention, not sequentially); a claimed instance is out of the pool before the job starts; an **errored, timed-out, or killed** run's instance is destroyed rather than returned — tested on the *failure* path explicitly, since that is where reuse leaks in; and every instance handed out is provably pristine. A pool that fails any of these has silently become `max_runs = N`.
- **`stdout` is bounded**: a run emitting more than `stdout_max_bytes` returns truncated output with `stdout_truncated=true` — never an unbounded string into agent context. Bulk output is only reachable via `files_out`.
- **Read-only `run_script` cannot escalate itself**: a run declared read-only (`files_out=[]`, `egress=DENY_ALL`) that attempts a write, requests egress, or requests `files_out` is **rejected**, not silently upgraded — the per-session approval must not be able to become a per-run write gate by accident (invariant 5).
- **`transform_files` is gated per run**: it opens `approval_request(kind='run_script')` and executes nothing until approved, at every kind (FR-040).
- **The toolkit is the contract**: `tmpl-coderun` has no network, so a generated `pip install` fails; the libraries enumerated in the `run_script` tool description are exactly those importable inside the sandbox — asserted by importing each one, so the description and the image cannot drift.
- **`tmpl-coderun` is never pooled**: a pool refuses to serve it at every kind, and `pooled = false` / `max_runs = 1` hold.
- **Stateless per job (invariant 12)**: two consecutive jobs on the **same** warm instance share no state — the second sees no cookie, `localStorage` entry, cached response, or temp file written by the first. Asserted under `service` (where instances are genuinely reused) as well as the per-job kinds.
- **Recycle bound (invariant 12)**: an instance is destroyed after `max_runs_per_sandbox` and after its TTL, at every kind. Under `service`, a **restart is observable** — the test asserts the process actually died, not merely that state was cleared, since clearing state does not evict a resident attacker.
- **`tmpl-coderun` is never pooled**: a `service`-kind pool refuses to serve `tmpl-coderun`, and its `max_runs_per_sandbox` is 1 at every kind — an instance that has executed model-authored code is never handed a second job.
- **`oneshot` obligations (all silent when broken)**: (a) the container's rootfs is **read-only** and its only writable paths are tmpfs — asserted by writing to `/`, `/usr`, and `/home` and requiring failure, **and** by confirming a file written to tmpfs is absent after a restart; (b) the replica process **exits** after exactly one job — a replica that handles a second job without an intervening exit is a failure, asserted by job-count-per-PID; (c) model-authored code has **no route to NATS or any other host** — asserted from inside the forked child, not from the supervisor.
- **Create-arg allowlist (invariant 11)**: a `SandboxSpec` carrying a hostile `template`, an out-of-bounds `vcpu`/`mem_mb`/`timeout_s`, or an attempt to smuggle a mount, capability, `hostNetwork`, `privileged`, `runtimeClassName`, or seccomp override is **rejected at spec-build time** — the tier never emits a create call containing an unallowlisted field. Tested with model-authored and config-authored inputs, since both are untrusted.
