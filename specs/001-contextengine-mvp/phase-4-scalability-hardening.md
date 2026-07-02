# Phase 4 Notes — Scalability & Resilience Hardening

**Status**: Backlog / not started · **Created**: 2026-06-20 · **Plan**: [plan.md](./plan.md)

These notes capture the work required to take AISAT-STUDIO from its **Phase 1 MVP
provisioning** (Go BFF 2 replicas, 3 Python worker pods per NATS subject, single
Qdrant/NATS cluster, Postgres primary + 1 read replica — see
[plan.md](./plan.md) "Scale/Scope") to **resilient operation under tens of
thousands of concurrent users** doing streaming AI chat and media uploads.

Phase 1 is **architecturally sound** for scale (async NATS seam, single LLM
gateway chokepoint, data-layer isolation, idempotent credit ledger, DLQs,
checkpoints). The items below are the *operational and horizontal-scaling*
mechanisms that were intentionally deferred or left unspecified for the MVP.
None of these are required to demonstrate the Phase 1 product; all are required
before high-concurrency production load.

> **Prerequisite already satisfied:** the five *rework-risk* architectural seams
> that must exist before this phase is purely additive are **locked in Phase 1**
> — JetStream durability, a separable SSE-relay tier, a workspace-partitionable
> credit outbox, a documented Qdrant re-shard trigger, and single-owner scheduled
> work in a dedicated `cmd/worker` role (external CronJob → NATS tick → queue group,
> idempotent atomic claims — so autoscaling never double-fires a timer; see
> [research.md §14–§15](./research.md) and [plan.md](./plan.md) "Scale/Scope"). Phase 4
> is therefore provisioning + HA + load validation, not redesign.

> Phase map: Phase 1 = Core App · Phase 2 = Evaluation Suite (+ Headroom eval) ·
> Phase 3 = Automated security red-teaming · **Phase 4 = Scale & Resilience
> Hardening (this doc)**.

---

## P0 — Blocking for high concurrency

### 1. Worker autoscaling (KEDA on NATS consumer lag)
- **Gap**: Worker pools are fixed at 3 pods/subject; KEDA was explicitly deferred
  to Phase 2 but never actually scheduled
  ([contracts/nats-subjects.md](./contracts/nats-subjects.md) "Per-subject scaling").
  A fixed pool turns a traffic spike into unbounded NATS queue depth and rising
  query latency.
- **Do**: Add KEDA `ScaledObject` per NATS subject keyed on consumer lag /
  pending-message count. Define min/max replica bounds per subject
  (`query.agent.*`, `ingestion.*`, `notify.*`, `billing.deduct.*`). Validate
  scale-up/down under synthetic load.

### 2. SSE connection ceiling & backpressure
- **Gap**: Every chat, every in-progress ingestion, and every notification inbox
  is a **long-lived SSE stream** held on the BFF
  ([contracts/sse-events.md](./contracts/sse-events.md)). Tens of thousands of
  concurrent users implies 30k–100k+ simultaneous open connections across only
  2 BFF replicas. No per-instance connection cap, FD budget, idle-timeout, or
  SSE heartbeat policy is specified. **This is the single biggest scaling risk.**
- **Do**: Set a per-BFF-instance max concurrent SSE connection limit + graceful
  rejection (`503` with retry hint) when exceeded; autoscale BFF replicas on
  active-connection count, not just CPU; add SSE keep-alive/heartbeat + server
  idle timeout to reclaim dead connections; load-test concurrent
  chat+ingest+notification streams to find the real per-pod ceiling.

### 3. Postgres connection pooling (PgBouncer)
- **Gap**: No connection pooler is specified. RLS uses `SET LOCAL
  app.workspace_id` per transaction
  ([data-model.md](./data-model.md)), making connection lifecycle critical. At
  high concurrency, `max_connections` exhaustion is a classic failure mode.
- **Do**: Introduce PgBouncer (transaction pooling, compatible with `SET LOCAL`),
  size pools per service, document read/write split to the existing read replica,
  and add replica-lag handling for read-after-write paths.

### 4. NATS JetStream flow control & load shedding
- **Gap**: No `MaxAckPending`, `ack_wait`, max queue depth, or stream
  retention/limits are specified. A slow consumer (LLM latency spike) can grow
  the stream until memory pressure or redelivery storms occur.
- **Do**: Configure bounded in-flight (`MaxAckPending`), sensible `ack_wait`,
  stream size/age limits, and an explicit overload/load-shedding policy (reject
  new queries with a clear `429`/`503` rather than degrade silently).

---

## P1 — Important for sustained load & availability

### 5. Qdrant HA & scale-out
- **Gap**: "Single Qdrant cluster", no sharding, replication, or quantization
  ([plan.md](./plan.md)). Dual-collection hybrid search (BM25/SPLADE + dense +
  rerank) on every query is CPU/RAM-heavy; one unreplicated node is a bottleneck
  and a SPOF on the core read path.
- **Do**: Add replication (failover) + sharding plan for the `personal` and
  `workspace` collections; evaluate scalar/product quantization for memory
  headroom; capacity-test hybrid query throughput.

### 6. Redis high availability
- **Gap**: One Redis cluster with logical DB/key-prefix role separation but no
  documented Sentinel/Cluster failover
  ([research.md §10](./research.md)). Redis holds the authoritative hot credit
  balance, LangGraph checkpoints, rate-limit counters, **and** SSE pub/sub — a
  loss degrades billing, streaming, and recovery at once.
- **Do**: Execute the Phase-2-anticipated split into independent clusters per
  durability profile; add Sentinel/Cluster failover; verify cold-start
  rehydration and hourly reconciliation behave correctly across a failover.
  **Locks are not the correctness boundary** (DB constraints are — [research.md §10/§15](./research.md));
  the Cluster-specific work is: hash-tag each workspace's keys onto one slot,
  accept `DECRBY` balance drift as an RPO/reconcile concern, and treat
  rate-limit counters + the opaque session store as fail-safe.

### 7. Operational resilience primitives
- **Gap**: No readiness/liveness probes, graceful drain (esp. for in-flight SSE
  on deploy/rollout), or hot-path request timeouts are documented.
- **Do**: Add `/healthz` liveness + `/readyz` readiness probes for every service;
  implement graceful shutdown that drains/relays SSE before termination; set
  explicit timeouts on synchronous hot-path calls (DB, Redis, downstream HTTP).

### 8. S3 / ingestion burst handling
- **Gap**: Direct-to-S3 presigned upload keeps payloads off app servers (good),
  but there's no documented throttle on presign issuance or ingestion-fan-in
  rate. A media-upload burst from thousands of users can flood
  `ingestion.*` subjects faster than the fixed worker pool drains.
- **Do**: Rate-limit presign issuance per workspace/user; ensure ingestion
  autoscaling (item 1) covers burst fan-in; confirm DLQ + retry behavior under
  sustained backlog.

---

## P2 — Validation & guardrails

### 9. Load & soak testing harness
- **Gap**: No throughput target (RPS/QPS), no concurrency target, and no
  load-test plan exist. The only stated budget is API p95 < 200ms (non-LLM)
  ([plan.md](./plan.md) "Performance Goals").
- **Do**: Define explicit SLOs (target concurrent users, RPS, SSE connections,
  p95/p99 per path). Build a k6/locust harness for the critical journeys:
  - Concurrent streaming chat (sustained open SSE + token streaming).
  - Media-upload bursts (presign → S3 → ingestion fan-in).
  - Mixed steady-state (chat + ingest + notifications + credit deducts).
  Run soak tests to surface connection leaks, queue growth, and replica-lag.

### 10. Per-tenant fairness / noisy-neighbor isolation
- **Gap**: Credit ceilings bound *cost*, but nothing bounds a single workspace's
  share of *compute* (worker slots, Qdrant CPU, DB connections) under contention.
- **Do**: Add per-workspace concurrency fairness (e.g., per-tenant in-flight
  query cap or weighted queueing) so one heavy tenant can't starve others.

---

## Cross-references
- Existing strengths to preserve: async query path
  ([research.md §6](./research.md)), idempotent credit ledger
  ([research.md §3](./research.md)), one-hop LLM fallback + circuit breaker
  ([contracts/llm-gateway.md](./contracts/llm-gateway.md)), DLQs + heartbeat
  re-queue ([contracts/nats-subjects.md](./contracts/nats-subjects.md),
  [data-model.md](./data-model.md)), partitioned tables
  ([data-model.md](./data-model.md)).
- These items add **horizontal scale + HA + operational hardening** on top of
  that foundation; they do not change the Phase 1 contracts.
