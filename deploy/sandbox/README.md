# Sandbox Runtime — the isolated-execution tier

The **single chokepoint for isolated code / tool execution**. Every untrusted browser
(crawl4ai), untrusted file parser (MarkItDown), or model-authored script (future
code-gen tools) runs inside an **ephemeral, credential-free, egress-locked sandbox** —
never in the orchestrator process, never with ambient credentials.

**Phase 1 runs the cheapest boundary that carries that contract: a hardened container, no
microVM. No metal, no nested virt, $0 incremental.** Which *kind* implements it depends on
where you are deploying — the targets differ in topology:

| Environment | `SANDBOX_KIND` | Why |
|-------------|----------------|-----|
| Local (macOS) | `docker` | gVisor is **Linux-only**; Docker Desktop ships only `runc`/`io.containerd.runc.v2`. No cluster either. |
| **DO droplet — first deploy** | **`service`** + `SANDBOX_RUNTIME=runsc` | Long-lived pools, **no runtime socket anywhere**. Per-job would need one on compose, and that is host-equivalent privilege — a bad trade at MVP volume. Linux, so gVisor is a one-flag change. |
| k3s / EKS | `k8s_pod` | RBAC ServiceAccount instead of a socket. The preferred posture. |
| EKS — `tmpl-coderun` | `k8s_pod` + `runsc` | gVisor is the **default** for model-authored code. No metal, no `/dev/kvm`, $0. |
| Only if threat model changes | `e2b_selfhost` | Firecracker. **Not otherwise required** — see below. |

Stronger boundaries are the same contract behind the same port — see
[the ratchet](#the-isolation-ratchet) below.

Contract (source of truth): [`../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md`](../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md).
This directory is the standalone-tier config home, mirroring [`deploy/do/llm-gateway/`](../do/llm-gateway/).

## What runs here

| Template | Toolchain | Consumer |
|----------|-----------|----------|
| [`templates/tmpl-crawl.Dockerfile`](templates/tmpl-crawl.Dockerfile) | Chromium + Playwright + Crawl4AI | crawl orchestrator (`ingestion.crawl.<ws>`) |
| [`templates/tmpl-convert.Dockerfile`](templates/tmpl-convert.Dockerfile) | MarkItDown + LibreOffice / pandoc | ingest convert step (`ingestion.{pdf,docx,image}.<ws>`) |
| [`templates/tmpl-coderun.Dockerfile`](templates/tmpl-coderun.Dockerfile) | Python + Node runtime (no secrets) | agent code-gen tool `run_script` / `transform_files` *(Phase 2)* |

The **same Dockerfile** is the container image under `docker`/`k8s_pod` (either runtime) and the microVM
rootfs under `e2b_selfhost` — changing the isolation backend does not rebuild the
toolchain. Templates are declared in [`templates/e2b.toml`](templates/e2b.toml) and built
by the sandbox build step (`make sandbox-templates`, TODO).

## App wiring (the swap seam)

Business code never talks to a sandbox vendor SDK — it calls the Python `Sandbox` port,
which forwards to this tier. Selected by config (same discipline as `LLM_GATEWAY_*`):

```bash
SANDBOX_KIND=k8s_pod      # service | k8s_pod | docker | e2b_*          (orchestration)
SANDBOX_RUNTIME=runc      # runc | runsc                                (isolation runtime)
SANDBOX_URL=http://sandbox-orchestrator:49983
SANDBOX_API_KEY=...       # control-plane auth (self-host) or E2B Cloud key
```

## The isolation ratchet

Boundary strength is bought **per workload, where the risk actually is** — not uniformly.
Every backend satisfies the identical security contract; they differ only in what kind of
escape they resist.

Two **orthogonal** axes control this. `SANDBOX_KIND` picks *orchestration*;
`SANDBOX_RUNTIME` (`runc` | `runsc`) picks the *isolation runtime* and is **per-template
overridable** — which is what makes the per-workload ratchet below expressible at all.
gVisor is a runtime flag on the orchestration you already run, **not** a backend of its own.

| `SANDBOX_KIND` | Boundary | Where | Incremental cost | Status |
|----------------|----------|-------|------------------|--------|
| **`k8s_pod`** | Pod — namespaces + cgroups + seccomp, non-root, read-only rootfs, caps dropped, `NetworkPolicy` deny-all. RBAC ServiceAccount, no socket | existing app node pool | **$0** | **preferred posture — needs k3s/EKS** |
| **`service`** | Long-lived pool over HTTP — **creates nothing, so no socket ever**. Stateless per job + recycle bound (inv. 11) | compose / any host | **$0** | **DO Phase 1** |
| `e2b_selfhost` | Firecracker microVM — hardware virtualization | tainted KVM/`*.metal` pool ([`sandbox.tf`](../eks/terraform/sandbox.tf), `sandbox_enabled`, **default false**) | **~$3k/mo** on AWS `*.metal`; ~$50–100/mo on Hetzner/OVH bare metal | **not required** — only if the threat model changes |
| `docker` | Sibling container per job. **Needs a runtime socket** | laptop | $0 | **local macOS dev only** — DO uses `service` to avoid the socket |
| `e2b_cloud` | Firecracker microVM, managed | vendor | usage-billed, no floor | dev / burst — **user files leave your infra under `tmpl-convert`** |

Per workload:

- **`tmpl-crawl` → hardened pod.** Public `https` pages, Chromium keeps its own
  multi-process sandbox, and a human accepts before anything is indexed. An escape needs a
  renderer 0-day *plus* a kernel LPE, and lands on a credential-free pod with default-deny
  egress. Not worth $3k/month at MVP volume.
- **`tmpl-convert` → gVisor** when the path ships. Untrusted user files through
  LibreOffice/pandoc/parsers is the genuinely higher-risk surface — worse CVE history than
  Chrome, and no internal sandbox of its own. `runsc` costs no infra.
- **`tmpl-coderun` → gVisor + `max_runs=1`** (Phase 2), on the ordinary `k8s_pod` path.
  gVisor's designed purpose *is* untrusted code — Google runs multi-tenant customer code
  on it (Cloud Run, App Engine, GKE Sandbox) — and a Python transform script is a far
  better fit for it than Chromium. A microVM is **stronger but not required**; buy it only
  if the threat model changes (third-party-authored code, hostile tenants, a compliance
  rule naming hardware isolation). **So the KVM pool may never need to exist.**

**Why the KVM path is off — and may stay off:** Firecracker needs `/dev/kvm`, and neither
standard EKS nodes (`t3.large`) nor standard DigitalOcean droplets expose nested
virtualization, so it requires bare metal — the ~$3k/month floor above. Since
`tmpl-coderun` now lands on gVisor rather than a microVM, **no Phase-1 or Phase-2 workload
requires `/dev/kvm` at all.**

The point of the port: **the isolation backend is a per-environment choice, not an app
change.** The crawl/convert/code-gen callers are byte-identical across all four, and the
[contract tests](../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md#contract-test-obligations)
pass unchanged against each — which is what makes the Phase-1 → Phase-2 upgrade a config
flip rather than a migration.

## What "stateless" means under `SANDBOX_KIND=service` (the DO posture)

Long-lived pools reuse instances, so the reset semantics have to be explicit. **State is
reset per job — not per tenant.** Per-job is strictly stronger: it resets even between two
jobs of the *same* workspace.

| Template | Per-job reset (kills **data** carryover) | Recycle bound (kills **compromise** carryover) |
|----------|------------------------------------------|------------------------------------------------|
| `tmpl-crawl` | a fresh `browser.newContext()` — new cookie jar, `localStorage`, `sessionStorage`, cache, service workers; context closed after the job | browser **process** recycled every `max_runs` (20) — which browsers need anyway for memory |
| `tmpl-convert` | a **fresh subprocess** with its own rlimits + a fresh temp dir, both destroyed with the job | container restarted every `max_runs` (**5** — tightened, this is the higher-risk surface) and on TTL |
| `tmpl-coderun` | **never pooled** — `pooled = false`, `max_runs = 1` | n/a; the instance is always destroyed after one run |

**The honest gap.** Clearing state does not evict an attacker already resident in the
process, so under `service` the workspace boundary is **soft**: compromise persistence is
*bounded* by recycle, not eliminated. Under `k8s_pod` it is a **hard** container boundary,
because the instance dies with the job. That is the accepted delta of running on compose
without a runtime socket — and it is exactly why `tmpl-coderun` never runs this way.

For convert, the fresh-subprocess-per-file design carries most of the weight: a parser RCE
lands in a short-lived child, inside an already non-root, read-only, caps-dropped,
network-denied container running under gVisor.

## Pod hardening (mandatory under `k8s_pod`)

The cheap boundary is only defensible if it is actually hardened. These are contract
obligations, not tuning knobs — a sandbox that would run without them must fail closed:

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities: { drop: ["ALL"] }
  seccompProfile: { type: RuntimeDefault }
automountServiceAccountToken: false
resources:
  limits: { cpu: <spec.vcpu>, memory: <spec.mem_mb>Mi }
```

plus a `NetworkPolicy` with **default-deny egress** (crawl's SSRF allowlist is granted only
through the egress proxy; convert gets no route at all).

**The PID cap is not in the pod spec.** Kubernetes sets per-pod process limits via the
kubelet's `podPidsLimit`, which is **node-level** config — so it must be set on the sandbox
node pool, not assumed from the manifest above. Without it, `mem_mb`/`vcpu` are not a real
cap: a fork bomb in a parser or a browser exhausts the node's process table long before it
reaches the memory limit.

## Local dev (`SANDBOX_KIND=docker`)

On macOS you **cannot** run the gVisor *runtime* (it is not a separate backend): `runsc` is a
Linux syscall implementation, and Docker Desktop's VM ships only `runc`/`io.containerd.runc.v2`.
So local dev is `SANDBOX_KIND=docker` at `SANDBOX_RUNTIME=runc`. This is a *laptop*
constraint, **not** a DO constraint — droplets run Linux, so `runsc` is available there and
is a one-flag change on the same `docker` kind.

```bash
docker run --rm \
  --user 65534:65534 \                 # non-root — REQUIRED, not optional
  --cap-drop=ALL --security-opt=no-new-privileges \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --pids-limit=128 --memory=512m --cpus=1.0 \
  --network=none \                     # tmpl-convert only; tmpl-crawl needs the proxy
  aisat-sandbox:tmpl-convert
```

Two rules this must not break:

- **No `-v` of any kind** (invariant 10) — no host bind mount *and* no named workspace
  volume. Files enter via S3 staging and leave via `files_out`. A persistent volume shared
  across runs also defeats the workspace-boundary recycle rule.
- **`--network=none` is per template.** Correct for `tmpl-convert` and `tmpl-coderun`;
  `tmpl-crawl` must instead be attached to the SSRF-allowlisted egress proxy network.

## Control-plane privilege (invariants 8–11) — read before wiring anything

**The boundary is not what fails first.** A pod that a renderer 0-day plus a kernel LPE
might cross is a bounded risk. A sandbox control plane holding a host runtime socket, or
building create-args from untrusted values, is *unbounded* — it hands out host-equivalent
privilege with no exploit required. A Firecracker fleet driven by an over-privileged
control plane is no safer than a pod.

**1. No component holds a container-runtime socket.** `/var/run/docker.sock` (or a CRI
socket) is host-equivalent: whoever reaches it can create a privileged container with `/`
bind-mounted, so containerizing the holder buys nothing. **Mounting it `:ro` does not
mitigate this** — read-only applies to the socket *file*, not the API; `POST
/containers/create` still succeeds.

- `k8s_pod` (at either runtime) creates sandboxes through the **Kubernetes API with an RBAC-scoped
  ServiceAccount** — `create`/`get`/`delete` on `pods` in the sandbox namespace only; no
  `exec`, no `privileged`, no node access, no cluster-scoped verbs. **Strictly less
  privilege than a socket**, which is the main reason the K8s path is primary.
- `docker` is single-host only. Where used, the socket goes to the **sandbox executor
  alone** — never the BFF, LLM gateway, MCP server, or any worker. The components chewing
  on untrusted channel input and model output must be furthest from it.
- **Rootless Docker is not the fix.** gVisor does not run cleanly under rootless Docker, so
  you cannot combine `docker` + `runsc` that way. The mitigation is **placement** (confine
  the socket, or split executor onto its own host) — or just use `k8s_pod`.

**2. No bind mounts, ever.** Files enter only as S3-staged `files_in` and leave only as
`files_out`. No host path is mounted into any sandbox, for any template. This is
structural, not hygienic: it makes mount-argument injection impossible (there is no mount
to inject), and it sidesteps the sibling-container trap where a container-created sibling
resolves bind sources against the *host* filesystem rather than the caller's — which fails
silently one way and exposes an unintended host path the other.

**3. Create-args come from a closed allowlist.** The spec is built from fields the tier
owns. **No config-, request-, or model-derived value reaches** mounts, network mode,
`hostNetwork`/`hostPID`/`hostIPC`, capabilities, `securityContext`, `runtimeClassName`,
`privileged`, or seccomp/AppArmor profile. Per-run values (`template`, `vcpu`, `mem_mb`,
`timeout_s`) are validated against the enumerated template registry and typed bounds
**before** spec construction. Enforce at spec-build time — documentation is not a control.

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

- **Buy cold-start relief in this order — do not start with a pool.** The dominant terms
  in a cold pod are *image pull* and *scheduling*, and both have fixes that carry no
  freshness state:
  1. **Pre-pull** template images onto sandbox nodes (DaemonSet warmer, or a pinned
     `@sha256` with `imagePullPolicy: IfNotPresent`). Biggest win by far — an uncached
     pull turns ~2 s into 30 s+ and no pool rescues that.
  2. **Scheduling headroom** — a negative-priority `PriorityClass` placeholder pod holding
     node capacity, preempted instantly by a real sandbox. Removes scheduling latency
     **without tracking which pods are fresh.**
  3. **Measure.** 1–2 s is typical after (1)+(2), and usually enough against a crawl path
     already spending seconds on fetch + distill. If it is, you never build a pool.
  4. **Only then** a pooled claim, and only for `tmpl-crawl` / `tmpl-convert`.
- **If you build a pool, it is a lease protocol — four obligations, all silent when broken:**
  atomic claim (no two jobs get the same instance, asserted under contention); claimed
  instances leave the pool at *claim* time; **errored / timed-out / killed runs destroy the
  instance rather than return it** (the one usually gotten wrong — the happy path is easy);
  and members are *provably* pristine. Miss any one and `max_runs = 1` has quietly become
  `max_runs = N`.
- **`tmpl-coderun` is never pooled.** HITL-gated, so the cold start is imperceptible —
  paying idle capacity *and* a claim protocol for invisible latency, on the template least
  tolerant of a bookkeeping bug, loses twice.
- Note pooling `k8s_pod` trades back part of what per-job bought (the *hard* workspace
  boundary). If warmth is the goal on the ingest templates, `SANDBOX_KIND=service` gives it
  with no claim protocol at all — choose deliberately.
- `max_runs_per_sandbox` is the **isolation dial** for the pod backend. A warm sandbox is
  reused for at most N jobs and is **always** recycled at a workspace boundary — never
  reused across workspaces (SC-001). Set it to 1 for strict per-run isolation at the cost
  of warmth.
- Cold start is **not** the dominant term on the crawl path anyway: Chromium launch plus
  page navigation (~1–5 s) plus the downstream distill set the floor at every backend.
- Sandbox capacity autoscales independently of the orchestrator pods (Phase 4: KEDA on
  JetStream lag → orchestrators; a second scaler → pod replicas, or microVM capacity once
  `e2b_selfhost` is on).
