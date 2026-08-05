# Contract: Audit Trail & Tamper-Evident Recording (reusable ports)

**Plan**: [../plan.md](../plan.md) | **Status**: Design addition — the reusability seam for the audit backbone (FR-023, FR-024). It factors the existing append-only, tamper-evident, partition-retained audit machinery into a small set of ports so the *same* engine records for any domain, any actor, and any durable sink without a schema change. **Changes no Phase 1 behavior** — the same rows land in `audit_log` / `agent_audit_log`; this only names the write/query seam that today is a set of inline `INSERT`s, the same treatment [metering-ports.md](./metering-ports.md), [notification-ports.md](./notification-ports.md), and [approval-ports.md](./approval-ports.md) gave their backbones.

The Phase 1 audit machinery is already correct on its *operational* axes (append-only, tamper-evident `result_hash`, tenant-scoped, time-partitioned retention), but it is packaged as **two divergent tables written by hand-rolled `INSERT`s** welded to four of *this* app's assumptions. This contract names the seam that removes that welding. Ports are given in Go (the kernel language); ContextEngine's two audit streams (generic member actions + AI tool calls) are presented at the end as **two bindings of one `Recorder`**, not as two engines.

---

## Why: the four couplings this removes

| # | Today's coupling | Evidence it is a coupling | The port that removes it |
|---|---|---|---|
| 1 | Two divergent tables, one per domain | `audit_log` (K: `actor_type/actor_id/action/resource_type/resource_id/metadata`) **and** `agent_audit_log` (P: `user_id/agent_role/tool_called/token_cost/result_hash`) are separate schemas ([data-model.md](../data-model.md) "Audit Record"); `sandbox_run` is a **third** "analogue of `agent_audit_log`". A cross-cutting "what happened to resource X" query must UNION three shapes, and every new audited surface adds a table | `Entry` + `Actor.Kind` — one append-only record; an AI tool call is `Actor{Kind:"agent"}`, a sandbox run `Actor{Kind:"sandbox"}`, never a new table |
| 2 | Tenant is a hard-coded `workspace_id` column | Both tables carry `workspace_id`; RLS keys on `app.workspace_id` — a reusing host whose isolation boundary is an org, an account, or a project needs a schema + RLS rewrite | `Tenant` — an opaque isolation subject the engine never interprets (the same seam metering-ports gave the billing subject) |
| 3 | Actor is split across typed columns | `audit_log.actor_type/actor_id` vs `agent_audit_log.user_id/agent_role` — two incompatible ways to say "who did this"; a service, a device, or an external integration fits neither cleanly | `Actor{Kind, ID, Role}` — one opaque principal; `Kind` is host-defined (`user`/`agent`/`service`/`system`/`device`) |
| 4 | The durable target is welded to a Postgres `INSERT` | Audit rows are written by inline writers (the generic `audit_log` writer + the `agent_audit_log` policy-repo writer) — there is no seam to also (or instead) ship to a SIEM, an append-only object store, or a compliance topic | `Sink` — a pluggable durable target; the recorder writes through a registry, never a hard-wired `INSERT` |

The rule: **the audit kernel is generic; only the `Sink` set, the `Action`/`Actor` taxonomy, and the `Tenant` binding are product-specific.** Everything that matters for an audit trail today (append-only, tamper-evident hashing, tenant-scoping, partitioned retention, no-body redaction) is preserved verbatim — it just stops assuming "workspace," a fixed two-table split, and Postgres-only.

> **This is a packaging refactor, not a behavior change.** FR-023 still records the same member actions and AI tool calls; FR-024's no-body rule still holds (only `result_hash`, never payloads). The two physical tables MAY remain as one `PostgresSink`'s partitions — what unifies is the *write path* (`Recorder.Record`) and the *query path* (`AuditQuery`), so a new audited surface is a `Record` call with a new `Actor.Kind`/`Action`, never a migration.

---

## Ports at a glance

```text
PRODUCERS (auth · billing · invite · agent · admin · sandbox · approval) — thin: emit one Entry
   │  Record(entry)        ── append-only, idempotent on entry.IdemKey
   │  RecordBatch(entries) ── one durable append for a burst (agent step → N tool calls)
   ▼
┌── Recorder (orchestration) ───────────────────────────────────────────────────┐
│   HashChain.Seal(entry, prevHash) → entry.Hash   (tamper-evidence, per scope)  │
│   redact(entry)  → strip bodies; keep refs + ResultHash only (FR-024)   PURE   │
│   Sink.Append(sealed)  → durable, idempotent on (tenant, idem_key)             │
└───────────────────────────────────────────────┬───────────────────────────────┘
        sync (security events) OR buffered (high-volume) — a knob, invariant 3    │
                                                 ▼
┌── Sink (the pluggable durable target · the load-bearing seam) ────────────────┐
│   PostgresSink   append-only INSERT → partitioned audit_log / agent_audit_log  │
│   (register another: KafkaSink · S3AppendSink · SplunkSink — never edit Record)│
└───────────────────────────────────────────────────────────────────────────────┘
        AuditQuery (driven) → tenant-scoped read/list/verify — SIEM, admin console, disputes
```

Four seams a host can swap independently: the **`Sink`** set (its durable targets), the **`Action`/`Actor` taxonomy** (its event + principal vocabulary), the **`Tenant`** binding (its isolation), and the **`HashChain`** (its tamper-evidence scheme). The reference impl uses Postgres, but nothing in the port signatures requires it.

---

## Domain types

```go
package audit

import (
	"context"
	"time"
)

// Tenant is the ISOLATION boundary an audit entry is scoped to — the RLS predicate source.
// The HOST decides what it means (workspace, organization, account, project); the kernel
// treats it only as an identity + a key source. Parameterizing this is what makes the
// workspace→organization re-anchor a config change, not a migration — the exact coupling
// metering-ports and notification-ports removed for their subjects.
type Tenant struct {
	Kind string // host-defined: "workspace" | "organization" | "account" | …
	ID   string // opaque, stable
}

// Tag is the Redis hash-tag / partition key for a tenant: hash-chain heads key as
// `audit:head:{tag}`, partitions/streams derive from it. The host decides what a tenant IS.
func (t Tenant) Tag() string { return t.Kind + ":" + t.ID }

// Actor is the OPAQUE principal that performed the action — the unification of today's
// `audit_log.actor_type/actor_id` and `agent_audit_log.user_id/agent_role`. The HOST decides
// what a Kind means; the kernel never special-cases one. This is what lets an AI tool call,
// a sandbox run, a service job, and a human action all be ONE record shape (coupling #1/#3).
type Actor struct {
	Kind string // host-defined: "user" | "agent" | "service" | "system" | "device" | "sandbox"
	ID   string // opaque, stable
	Role string // OPTIONAL host role: "admin" | "automation" | agent_role | "" — descriptive, never a routing input
}

// Action is a REGISTERED action verb (generalizes both the free-text `action` and the
// `tool_called`). A string, not a DB enum: a new audited action is a value, never an
// ALTER TYPE migration. Convention: dotted, past-or-imperative — "member.invited",
// "document.access_level_changed", "tool.search_workspace_knowledge", "approval.resolved".
type Action string

// Subject is WHAT the action was performed on — the unification of `resource_type/resource_id`
// (and the implicit "the tool's target"). Opaque: the kernel never dereferences it.
type Subject struct {
	Type string // host taxonomy: "note" | "document" | "member" | "invite" | "agent_run" | "approval" | …
	ID   string // opaque; "" when the action has no single subject (e.g. a login)
}

// Severity classifies an entry for alerting + retention tiering; host-extensible via config.
type Severity string // "info" | "notice" | "security" | "critical"

// Entry is ONE immutable, append-only audit record — the unit the engine seals + dedupes on.
// IdemKey is REQUIRED: it is the retry/dedup identity that makes Record exactly-once so a
// producer's at-least-once bus cannot double-log the same event (FR-023).
type Entry struct {
	Tenant     Tenant
	Actor      Actor
	Action     Action
	Subject    Subject
	Severity   Severity
	Attributes map[string]string // host detail: token_cost, trace_id, old→new value, provider — see the no-body invariant
	ResultHash string            // OPTIONAL tamper-evident fingerprint of a result/body that is NOT stored (parity with agent_audit_log.result_hash / llm_call_log no-body, FR-024)
	IdemKey    string            // REQUIRED — derived from the originating resource + event
	TraceID    string            // correlation id (OTel), for cross-system stitching
	OccurredAt time.Time
}

// Sealed is an Entry after the HashChain has stamped it — the durable unit a Sink appends.
type Sealed struct {
	Entry
	Seq      int64  // monotonic per-tenant sequence — a gap is evidence of a dropped/deleted row
	PrevHash string // hash of the previous sealed entry for this tenant ("" for the first)
	Hash     string // H(PrevHash || canonical(Entry) || Seq) — the tamper-evidence link
}

// Receipt is the outcome of an idempotent Record. Applied=false ⇒ this IdemKey was already
// recorded and this call was a no-op (a replay) — the producer relies on that to stay exactly-once.
type Receipt struct {
	ID      string
	IdemKey string
	Applied bool  // false = idempotent replay, already recorded
	Seq     int64 // the tenant sequence assigned (0 on replay)
}
```

---

## Port: `Sink` — the pluggable durable target (the load-bearing seam)

```go
// Sink is ONE durable append target. PostgresSink is the Phase 1 implementation; a Kafka
// topic, an append-only S3 object log, or a SIEM forwarder is added by REGISTERING another
// Sink — never by editing the recorder. This is the audit analogue of metering's Pricer and
// notification's Channel: the one place a new deployment plugs in its own backend.
type Sink interface {
	Kind() string // "postgres" | "kafka" | "s3_append" | "splunk" | …

	// Append durably writes ONE sealed entry. MUST be idempotent on (e.Tenant, e.IdemKey):
	// a producer/recorder re-drive after a crash must not write a second row (the durable
	// UNIQUE(tenant, idem_key) is the backstop). MUST be append-only — it exposes no update
	// or delete; the ONLY removal path is Prune (retention), never an in-place edit.
	Append(ctx context.Context, e Sealed) (Receipt, error)

	// AppendBatch writes N sealed entries for one tenant atomically (all-or-nothing) so a
	// multi-tool agent step lands as one durable unit — no partially-logged step.
	AppendBatch(ctx context.Context, es []Sealed) ([]Receipt, error)

	// Prune enforces retention: it DROPs whole time partitions older than the window
	// (never a row-level DELETE, which would break the hash chain's Seq contiguity within a
	// retained window). Returns the count reclaimed. (FR-039-style bounded growth.)
	Prune(ctx context.Context, olderThan time.Duration) (pruned int, err error)
}

// SinkRegistry maps a Sink kind to its impl. Registering (or fanning out to several) sinks is
// a wiring-time Register call in cmd/ — never an edit to Record or a schema change.
type SinkRegistry interface {
	Register(s Sink)
	Get(kind string) (Sink, bool)
	Kinds() []string
}
```

**Why this is the whole game.** A compliance backhaul to a SIEM is writing one `Sink` and one `Register` line (or fanning the recorder to `["postgres","kafka"]`), with zero edits to sealing, redaction, idempotency, tenant-scoping, or retention. Contrast today's inline `INSERT audit_log` / `INSERT agent_audit_log`, where a second backend means editing every writer.

---

## Port: `Recorder` — orchestration producers actually use

```go
// Recorder is the single entry point producers depend on. It composes HashChain (seal) +
// redaction + Sink(s) so callers never touch hashing, partition keys, or the backend. Producers
// stay THIN: they emit an Entry, nothing more.
type Recorder interface {
	// Record redacts, seals (assigns Seq + chains Hash under a per-tenant head), and appends
	// ONE entry, idempotently on e.IdemKey. A replay is a no-op (Applied=false), no second row,
	// no Seq consumed. Whether it blocks on the durable append or buffers is the durability knob
	// (invariant 3) — but a "security"/"critical" Severity ALWAYS writes synchronously.
	Record(ctx context.Context, e Entry) (Receipt, error)

	// RecordBatch seals + appends N entries for one tenant as one durable unit (an agent step
	// that called several tools lands atomically). Each carries its own IdemKey.
	RecordBatch(ctx context.Context, es []Entry) ([]Receipt, error)
}
```

## Port: `HashChain` — tamper-evidence (pure, per-tenant)

```go
// HashChain makes the log tamper-EVIDENT (not tamper-proof): each entry links to the previous
// via PrevHash and carries a monotonic Seq, so a deleted or edited row breaks the chain / leaves
// a Seq gap that Verify detects. Generalizes today's per-row `result_hash` into a per-tenant
// linked history. Seal MUST be deterministic over (prevHash, canonical(entry), seq) — no clock,
// no I/O in the hash — so Verify can recompute it during an audit/dispute.
type HashChain interface {
	// Seal assigns the next Seq for e.Tenant and computes Hash = H(prevHash || canonical(e) || seq),
	// advancing the per-tenant head atomically (SET on audit:head:{tag}). Concurrency-safe: two
	// concurrent Records for one tenant get distinct, contiguous Seqs.
	Seal(ctx context.Context, e Entry) (Sealed, error)

	// Verify re-walks a tenant's chain over [from,to] and reports the first break (edited hash,
	// missing Seq, reordered link) — the primitive an integrity audit / dispute runs.
	Verify(ctx context.Context, t Tenant, from, to time.Time) (VerifyReport, error)
}

type VerifyReport struct {
	Tenant   Tenant
	Checked  int
	Intact   bool
	BreakSeq int64  // first offending Seq (0 when Intact)
	Detail   string // "hash_mismatch" | "seq_gap" | "reordered" | ""
}
```

## Port: `AuditQuery` — tenant-scoped reads (driven)

```go
// AuditQuery is the read side — the admin console, a dispute investigation, a SIEM export.
// Every method is tenant-scoped at the data layer (RLS); a caller can never read another
// tenant's trail regardless of role (invariant 2). READ-ONLY — there is no mutating method
// anywhere on the audit surface (invariant 1).
type AuditQuery interface {
	// List returns entries for a tenant matching the filter, newest-first, paginated.
	List(ctx context.Context, t Tenant, f Filter) ([]Sealed, Cursor, error)

	// BySubject returns the full history of one resource ("what happened to note X") — the
	// cross-cutting query the two-table split made a painful UNION.
	BySubject(ctx context.Context, t Tenant, s Subject, f Filter) ([]Sealed, Cursor, error)
}

type Filter struct {
	Actors   []Actor    // optional actor filter (by Kind/ID)
	Actions  []Action   // optional action filter
	Severity []Severity // optional severity filter
	Since    time.Time
	Until    time.Time
	Limit    int
	After    Cursor // pagination
}

type Cursor string
```

---

## Invariants every implementation MUST uphold

1. **Append-only (release-grade).** The audit surface exposes **no** update or delete method — not on `Sink`, not on `Recorder`, not on `AuditQuery`. The only removal is `Sink.Prune`, which DROPs whole time partitions past the retention window, never individual rows. An audit trail that can be edited in place is not an audit trail.
2. **Tenant-scoping at the data layer.** Every read is constrained to its `Tenant` by an RLS policy (`workspace_id = current_setting('app.workspace_id')`); a trail is never visible across tenants regardless of clearance/role. Scoping lives in the sink/store, not application code (parity with the notification recipient-scoping invariant).
3. **Durability posture is explicit, and security events are synchronous.** `Record` picks an `AuditDurability` (below). High-volume, low-stakes entries (per-tool-call telemetry) MAY buffer; **any `Severity ∈ {security, critical}` MUST be written synchronously before the producing action is acknowledged** — a dropped security event is a compliance failure (OWASP A09 / logging L1). The knob never applies to security-relevant entries.
4. **Idempotent on IdemKey.** Every `Record` carries an `IdemKey`; the durable `UNIQUE(tenant, idem_key)` collapses a producer's at-least-once redelivery to exactly one row (and one consumed `Seq`). `Receipt.Applied=false` reports a replay.
5. **No bodies — refs + hashes only.** An `Entry` stores deep-link refs and a `ResultHash`, never file contents, generated code, prompts, responses, or secrets (parity with the `agent_audit_log` / `llm_call_log` no-body rule, FR-024). Redaction is a **pure** step in `Record`, applied before sealing, so the hash covers the redacted form. `Attributes` is for audit detail (trace_id, token_cost, old→new value), never a payload dump.
6. **Tamper-evident, not just append-only.** Each entry links to the previous via `PrevHash` + a monotonic per-tenant `Seq`; `HashChain.Verify` detects an edited hash, a missing `Seq`, or a reorder. This upgrades today's standalone per-row `result_hash` (which fingerprints a *result body*, not the log) into a verifiable *history*. It is the one part of this contract that is **additive to the schema, not pure repackaging**: each audit partition gains `seq`/`prev_hash`/`entry_hash` columns and a per-tenant Redis chain head (`audit:head:{tag}`) — see [data-model.md](../data-model.md) "Audit Record". What is *stored* still adds no bodies (invariant 5): the new columns are chain metadata, not payloads; `result_hash` remains the no-body result fingerprint alongside them.
7. **Sealing is deterministic + concurrency-safe.** `HashChain.Seal` is pure over `(prevHash, canonical(entry), seq)` — no clock, no I/O in the hash — and assigns contiguous `Seq`s under concurrency (atomic head advance). Determinism is what makes `Verify` (and a dispute replay) reproducible.
8. **Pluggable sink, never an inline INSERT.** The recorder writes through the `SinkRegistry`; a second/replacement backend (SIEM, Kafka, S3) is a `Register`, never an edit to a producer. Fan-out to multiple sinks is all-or-nothing per entry (a partial write re-drives on the shared `IdemKey`).
9. **Bounded growth.** Retention is a partition `DROP` (`PARTITION BY RANGE (created_at)`), so expiry is O(1) and List/BySubject stay fast; retention windows are per-`Severity` configurable (security entries retained longer). *(Matches the existing partitioned-by-`created_at` audit tables.)*
10. **Opacity.** The kernel never parses, ranks, or special-cases a `Tenant`, `Actor`, `Subject`, or `Action`. Re-anchoring the tenant (workspace→organization) or adding an actor kind (`device`, `sandbox`) or an action changes only what the host constructs — never a kernel signature or a migration.

---

## Audit durability (customizable knob)

One config selects the durability/latency trade for `Record`, without changing any port signature. **Security/critical severities ignore it and always write synchronously (invariant 3).**

| `AuditDurability` | Write path | On crash | Use when |
|---|---|---|---|
| `sync` (default for `security`/`critical`) | Seal + `Sink.Append` before the producer acks its action | Nothing lost — the entry is durable before the action is confirmed | Access-control decisions, approvals, auth events, admin actions, credit grants |
| `buffered` | Seal + enqueue to a durable local buffer/outbox; a drainer appends | Bounded loss only for `info`/`notice`; survives if the buffer is durable | High-volume `info` telemetry (per-tool-call rows) where a sub-second RPO on non-security rows is acceptable |

`buffered` reuses the same outbox discipline metering and notifications already run; `sync` is the default the moment an entry is security-relevant. A host picks per-severity (or per-deployment) — this is the main "how strict is my trail" dial.

---

## Reference wiring: ContextEngine audit as TWO bindings of ONE Recorder

The Phase 1 system is these ports bound to *this* app — nothing in the kernel knows there were ever "two tables":

| Generic port / type | ContextEngine (Phase 1) binding |
|---|---|
| `Tenant` | `{Kind: "workspace", ID: workspace_id}` → Phase 2 `{Kind: "organization", …}` — a binding change, no kernel edit |
| `Actor` (member action) | `{Kind: "user", ID: user_id, Role: member_role}` → today's `audit_log.actor_type/actor_id` |
| `Actor` (AI tool call) | `{Kind: "agent", ID: user_id, Role: agent_role}` → today's `agent_audit_log.user_id/agent_role` |
| `Actor` (sandbox run) | `{Kind: "sandbox", ID: user_id}` → today's `sandbox_run` (the third "analogue" folds in here) |
| `Action` | member: `"member.invited"`/`"document.access_level_changed"`/`"approval.resolved"`; agent: `tool.<tool_called>` — a registry, not a Postgres enum |
| `Subject` | `{Type: resource_type, ID: resource_id}` (member) / the tool's target (agent) |
| `Attributes` | `audit_log.metadata` JSONB (member) / `{token_cost, trace_id}` (agent) — detail, never bodies |
| `ResultHash` | `agent_audit_log.result_hash` / `sandbox_run.result_hash` (tamper-evident, no body) |
| `Sink` | `PostgresSink` over the partitioned `audit_log` + `agent_audit_log` tables (kept as its physical partitions) |
| `Recorder` producers | the auth/invite/admin/policy/approval writers (`security` sync) + the MCP policy wrapper's per-tool-call row (`info` buffered) |

Swapping ContextEngine for, say, a fintech ledger app that must forward to Splunk = register a `SplunkSink` alongside `PostgresSink`, set `Tenant.Kind="account"`, define its `Action`s. The sealing, redaction, idempotency, tenant-scoping, and retention code are untouched. Re-anchoring workspace→organization is one `Tenant` binding change (the same move metering and notify already documented).

---

## Contract-test skeleton

These validate *any* implementation of the ports against the invariants, so a swapped `Sink` (Kafka/S3) or a different `HashChain` is held to the same guarantees. The `HashChain` suite is pure (no infra beyond the head store); the `Sink`/`Recorder` suites run against a real impl via Testcontainers (`//go:build integration`, per the repo test convention).

```go
package audit_test

// HashChainContract runs against ANY audit.HashChain — pure, no infra beyond the head store.
func HashChainContract(t *testing.T, newChain func(t *testing.T) audit.HashChain) {
	ctx := context.Background()
	ws := audit.Tenant{Kind: "workspace", ID: uuidv7()}
	mk := func(idem string) audit.Entry {
		return audit.Entry{Tenant: ws, Actor: audit.Actor{Kind: "user", ID: "u1"},
			Action: "member.invited", Subject: audit.Subject{Type: "invite", ID: idem},
			Severity: "security", IdemKey: idem, OccurredAt: time.Now()}
	}

	t.Run("seq is contiguous + monotonic per tenant", func(t *testing.T) {
		c := newChain(t)
		a, _ := c.Seal(ctx, mk("e1")); b, _ := c.Seal(ctx, mk("e2"))
		if b.Seq != a.Seq+1 { t.Fatalf("seq not contiguous: %d then %d", a.Seq, b.Seq) }
	})
	t.Run("each entry links the previous hash", func(t *testing.T) {
		c := newChain(t)
		a, _ := c.Seal(ctx, mk("e1")); b, _ := c.Seal(ctx, mk("e2"))
		if b.PrevHash != a.Hash { t.Fatal("chain link broken: PrevHash != previous Hash") }
	})
	t.Run("fresh chain verifies intact (seal is deterministic)", func(t *testing.T) {
		c := newChain(t)
		_, _ = c.Seal(ctx, mk("e1"))
		rep, err := c.Verify(ctx, ws, time.Time{}, time.Now()); mustNoErr(t, err)
		if !rep.Intact || rep.Checked == 0 { t.Fatalf("fresh chain must verify intact: %+v", rep) }
	})
	t.Run("verify detects an edited hash / seq gap", func(t *testing.T) {
		c := newChain(t); _, _ = c.Seal(ctx, mk("e1")); _, _ = c.Seal(ctx, mk("e2"))
		tamper(t, ws) // out-of-band mutate/delete a row
		rep, _ := c.Verify(ctx, ws, time.Time{}, time.Now())
		if rep.Intact { t.Fatal("tampered chain must NOT verify intact") }
	})
}

// SinkContract runs against a REAL audit.Sink (Testcontainers Postgres).  //go:build integration
func SinkContract(t *testing.T, newSink func(t *testing.T) audit.Sink) {
	ctx := context.Background()
	ws := audit.Tenant{Kind: "workspace", ID: uuidv7()}
	seal := func(idem string) audit.Sealed {
		return audit.Sealed{Entry: audit.Entry{Tenant: ws, Actor: audit.Actor{Kind: "user", ID: "u1"},
			Action: "member.invited", Severity: "security", IdemKey: idem, OccurredAt: time.Now()}}
	}

	t.Run("append is idempotent on (tenant, idem_key)", func(t *testing.T) {
		s := newSink(t)
		r1, err := s.Append(ctx, seal("e1")); mustNoErr(t, err)
		if !r1.Applied { t.Fatal("first append should apply") }
		r2, err := s.Append(ctx, seal("e1")); mustNoErr(t, err) // replay
		if r2.Applied { t.Fatal("replay must be a no-op (Applied=false)") }
	})
	t.Run("no update/delete surface exists", func(t *testing.T) {
		// COMPILE-TIME invariant: audit.Sink has no Update/Delete method. This test documents it;
		// a reviewer verifies the interface never grows a row-level mutator.
	})
	t.Run("prune drops old partitions but keeps the retained window intact", func(t *testing.T) {
		s := newSink(t); _, _ = s.Append(ctx, seal("keep"))
		_, err := s.Prune(ctx, 90*24*time.Hour); mustNoErr(t, err)
		got := listAll(t, s, ws) // the just-written entry is inside the window and MUST survive
		if len(got) == 0 { t.Fatal("prune removed an in-window entry") }
	})
	t.Run("reads are tenant-scoped", func(t *testing.T) {
		// an entry written under ws is never returned for a different tenant (RLS) — asserted
		// against the AuditQuery bound to the same store.
	})
}
```

---

## Deployment topology: embedded library **or** standalone audit service

**Yes — the audit engine can run as its own runtime service, and the ports are what make it a config+wiring change rather than a rewrite** (the same library↔service move metering, notification, and the LLM gateway make). Two shapes, one set of interfaces:

1. **Embedded library (Phase 1 default).** Callers import `kernel/audit`; producers call `Record` in-process (a fast seal + append). The `buffered` drainer runs in the `cmd/worker` role.
2. **Standalone audit service.** Wrap the *same* ports behind a thin gRPC facade (`AuditService`), hand producers a client stub, and the service owns the store + hash chain + sink registry. Only the `Recorder` binding changes (in-process impl → client stub); producer logic does not. This is the natural shape once a *second* product must share a compliance trail or a central SIEM feed.

What makes it **not free** (decide before extracting):
- **Sync latency for security events** — invariant 3 forces `security`/`critical` entries to be durable before the action acks, so a remote hop is on the critical path for those; co-locate the store or accept the added latency for high-stakes actions only.
- **Hash-chain ownership** — the per-tenant chain head is authoritative state; a standalone service must own it (never two writers advancing one tenant's `Seq`), exactly like `LedgerWriter` owns the ledger.
- **Auth between producer ↔ service** — the trail is evidence, so producers authenticate (mTLS / signed token) and `Tenant`/`Actor` are authoritative from the trusted producer, never from untrusted content.
- **Redaction ownership moves with the service** — the no-body rule (invariant 5) is enforced service-side so a misbehaving producer cannot smuggle a payload into the durable trail.

**Recommended posture:** start **embedded**; extract to a **co-located service** the moment a second product needs the same trail or a central SIEM, at which point it is a deploy/config change plus a client stub — exactly the guidance metering, notification, and the LLM gateway already follow.

---

## Alignment note (tasks)

This contract has **no implementation task yet** — Phase 1 tasks write audit rows inline (the generic `audit_log` writer and the `agent_audit_log` policy-repo writer) rather than through a `Recorder`/`Sink` port. Bringing tasks into alignment with this contract means:

- a kernel `audit` port task (`backend-go/kernel/audit/` — `Recorder`/`Sink`/`HashChain`/`AuditQuery` + `Tenant`/`Actor`/`Action`/`Subject`/`Entry`/`Sealed`; `depguard`: `kernel/audit/**` may not import `internal/**`, the same rule as `kernel/metering`/`kernel/notify`/`kernel/approval`), and
- an audit **contract-test** task running `HashChainContract` + `SinkContract` (+ the append-only / tenant-scope / no-body invariants),

with the existing inline writers refactored to call `Recorder.Record`. Until then, audit is the one backbone in this system that is production-correct but **not** yet behind its reusable seam — this document is the seam; the tasks are the follow-up.
