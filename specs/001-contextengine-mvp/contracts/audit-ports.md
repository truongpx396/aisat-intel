# Contract: Audit Trail & Tamper-Evident Recording — **binding to `intel-audit`**

**Plan**: [../plan.md](../plan.md) | **Status**: Pointer + binding. The engine now lives upstream.

> ### The design moved
> The audit engine designed here — `Recorder`/`Sink`/`SinkRegistry`/`HashChain`/`AuditQuery` over an
> opaque `Tenant`/`Actor`/`Action`/`Subject`, the invariants, the durability knob, the hexagonal
> layout, the conformance suites — is now an independent, reusable project:
>
> ### 📦 **[truongpx396/intel-audit](https://github.com/truongpx396/intel-audit)**
> **Canonical contract**: [`specs/001-audit-core/contracts/audit-ports.md`](https://github.com/truongpx396/intel-audit/blob/main/specs/001-audit-core/contracts/audit-ports.md)
>
> Its git history came across intact, so this contract's evolution is traceable there. That
> repository is **authoritative** for the engine; this file records only how ContextEngine *binds* to
> it. Do not re-specify engine behaviour here — change it upstream.

This contract closed with an honest admission: *"audit is the one backbone in this system that is
production-correct but **not** yet behind its reusable seam — this document is the seam; the tasks
are the follow-up."* The follow-up is upstream, where the seam is now the product.

---

## What ContextEngine supplies

| Binding | ContextEngine's value |
|---|---|
| **`Realm`** | `aisat-intel` |
| **`Tenant`** | `{Kind: "workspace", ID: workspace_id}` — Phase 2 re-anchors to `{Kind: "organization", …}` ([draft-plan.md — Tenancy](../../draft-plan.md#phase-2--tenancy--delegated-administration)) |
| **`Actor`** (member) | `{Kind: "user", ID: user_id, Role: member_role}` |
| **`Actor`** (AI tool call) | `{Kind: "agent", ID: user_id, Role: agent_role}` |
| **`Actor`** (sandbox run) | `{Kind: "sandbox", ID: user_id}` |
| **`Action`** | member: `member.invited` · `document.access_level_changed` · `approval.resolved`; agent: `tool.<tool_called>`; sandbox: `sandbox.<feature>` |
| **`Subject`** | `{Type: resource_type, ID: resource_id}` |
| **`Severity`** | `security` for auth/permission/approval/admin actions and credit grants; `info` for per-tool-call telemetry |
| **`Sink`** | `PostgresSink` only. No SIEM backhaul in Phase 1 |
| Deployment shape | **embedded library** in `backend-go` (Go host, one product) |

## Where the seam touches this spec

| Concern | This repo |
|---|---|
| Producers | auth · invite · admin · policy · approval writers (`security`, synchronous) + the MCP policy wrapper's per-tool-call row (`info`) |
| Storage | the partitioned audit tables ([data-model.md](../data-model.md)) |
| Read surface | admin console listing; `GET /audit/*` is not exposed in Phase 1 |
| Tasks | T022c implements the port against the upstream interfaces; T022d runs upstream's conformance suites; T019/T020a/T113 create the tables |

## Four upstream findings that change this repo's migrations

All four were found upstream by **applying** this contract's schema rather than reading it. The first
three change what T019/T020a/T113 must create, so they are not optional reading. The full set is in
upstream's
[design-decisions.md](https://github.com/truongpx396/intel-audit/blob/main/specs/001-audit-core/design-decisions.md).

1. **The idempotency guard cannot live on the audit table.** Invariant 4 required a durable
   `UNIQUE (tenant, idem_key)` and invariant 9 required `PARTITION BY RANGE (created_at)`. PostgreSQL
   rejects that combination, and adding `created_at` to the constraint would satisfy Postgres while
   silently destroying the guarantee. Upstream uses a non-partitioned `audit_idem` guard written in
   the same transaction. **This is the third subsystem here to carry that pattern**, after
   [`credit_ledger`](https://github.com/truongpx396/intel-payment) and
   [`notifications`](https://github.com/truongpx396/intel-notification) — one unconstructible shape
   copied across three contracts and applied in none.

2. **Retention and tamper-evidence contradicted each other.** Invariant 6 treats a `seq` gap as
   evidence of tampering; invariant 9 retires whole partitions. After a single retention run the
   chain begins at seq N with nothing before it — exactly what deletion looks like — so `Verify`
   reports tampering on a healthy log, on every tenant, permanently. Upstream requires an immutable
   `audit_chain_anchor` recorded **before** a range is retired. Until this repo adopts it, **enabling
   retention on the audit tables makes the chain unverifiable and the damage is not repairable** —
   the entries are gone, so the gap can never be explained afterwards.

3. **The chain head cannot live in Redis.** [data-model.md](../data-model.md) called
   `audit:head:{kind}:{tenant}` "authoritative Redis state". A cache cannot own a sequence: losing it
   restarts `seq`, producing either a collision or a permanent false break no replay repairs.
   Upstream makes the head a durable table advanced inside the append transaction, with Redis
   optional and advisory. This also contradicts this product's own rule — the
   [metering](./metering-ports.md) and [notification](./notification-ports.md) bindings both insist
   Redis is a fast path and never the source of truth. Audit was the one place that rule was dropped.

4. **Append-only needs the database to enforce it.** Invariant 1 guaranteed immutability by the
   *absence* of an update method, which constrains the application and nothing else — not a `psql`
   session, not a migration script, and not the attacker the trail exists to catch. Upstream adds a
   mutation-rejecting trigger and least-privilege grants. T022c should wire the same.

## What upstream is, and is not

Upstream is explicit that the trail is **tamper-evident, not tamper-proof**: it detects modification
by anyone without simultaneous database *and* deployment access, and does **not** defend against a
privileged operator, who could drop the trigger and recompute the chain. Closing that needs external
anchoring, which is
[upstream Phase 2](https://github.com/truongpx396/intel-audit/tree/main/specs/002-anchoring-legal-hold)
and not built. If a compliance obligation here ever requires "prove we could not have altered this",
this binding does not satisfy it today.
