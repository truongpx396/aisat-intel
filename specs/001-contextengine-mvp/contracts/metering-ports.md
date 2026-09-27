# Contract: Metering & Credit Ledger — **binding to `intel-payment`**

**Plan**: [../plan.md](../plan.md) | **Status**: Pointer + binding. The engine now lives upstream.

> ### The design moved
> The metering/credit engine designed here — `Scope`/`Pricer`/`Ledger`/`LedgerWriter`/`Meter`, the
> invariants, the settlement-durability knob, the hexagonal layout, the machine-enforced boundary,
> the conformance suites — is now an independent, reusable project:
>
> ### 📦 **[truongpx396/intel-payment](https://github.com/truongpx396/intel-payment)**
> **Canonical contract**: [`specs/001-metering-billing-core/contracts/metering-ports.md`](https://github.com/truongpx396/intel-payment/blob/main/specs/001-metering-billing-core/contracts/metering-ports.md)
>
> Its git history came across intact, so this contract's evolution is traceable there. That
> repository is **authoritative** for the engine; this file records only how ContextEngine
> *binds* to it. Do not re-specify engine behaviour here — change it upstream.

This was always the plan. The contract's own litmus test was *"could I move this into its own
repo and have it compile with zero edits?"*, and the boundary was lint-enforced so the answer
stayed yes. It did, so it moved.

---

## What ContextEngine supplies

The engine is generic; a host provides exactly three things.

| Binding | ContextEngine's value |
|---|---|
| **`Realm`** | `aisat-intel` |
| **`Scope`** | `{Kind: "workspace", ID: workspace_id}` — Phase 2 re-anchors to `{Kind: "organization", …}`. A binding change here, not a migration ([draft-plan.md — Tenancy](../../draft-plan.md#phase-2--tenancy--delegated-administration)) |
| **`Pricer`** | `LLMTokenPricer` over `llm_input_token` / `llm_cached_token` / `llm_output_token`, from the gateway's returned usage ([llm-gateway.md](./llm-gateway.md)). Upstream ships this as its `llmtoken` reference pricer |

## Configuration (data upstream, values ours)

| Upstream concept | ContextEngine's configuration |
|---|---|
| Rate card | versioned rows; `MicrosPerCredit` set so 1 credit ≈ $0.001 with margin ([draft-plan.md — pricing](../../draft-plan.md)) |
| `Limit[]` | three ceilings: `workspace_balance` (Balance → `402`), `role_daily` on `agent_policies.token_budget_day` (Daily → `429`), `user_daily` (Daily → `429`), `WarnAt = 0.8` (FR-016…FR-020) |
| `Charge.Reason` / `Grant.Reason` | `credit_ledger.operation_type`: `query` · `ingest` · `enrich` · `caption` · `sandbox.crawl` · `sandbox.convert` · `sandbox.run_script` |
| `Window: Job` | the long-horizon run cap. `agent_run.credits_cap` becomes a `Job`-window `Limit` on `{Kind:"agent_run", ID:run_id}` — a counter, so no ledger rows accrue per run and an abandoned run leaks nothing ([draft-idea.md §4.5](../../../draft-idea.md)) |
| `Transfer` | Phase 2 org pool → workspace allocation. `organization_credits` is the pool, `workspace_credits` the allocation, with `MaxDestBalance` as the optional per-workspace cap ([Tenancy](../../draft-plan.md#phase-2--tenancy--delegated-administration)) |
| `SettlementDurability` | `outbox` — bounded under-bill RPO is acceptable for commodity token metering |
| `AdmitFailPolicy` | `fail_closed` |
| Deployment shape | **embedded library** in `backend-go` (Go host, one product). The durable writer runs in `cmd/worker` |

## Where the seam touches this spec

| Concern | This repo |
|---|---|
| Spend producers | Python workers publish `billing.deduct.<ws>` ([nats-subjects.md](./nats-subjects.md)); the Go worker is the sole ledger writer |
| Balance surface | `GET /credits` ([bff-rest.md](./bff-rest.md)), rendered per [credits-ui-ports.md](./credits-ui-ports.md) |
| Blocked operations | `402 payment_required` / `429 limit_reached`, never a silent failure (SC-010) |
| Tasks | T011 defines `kernel/meter.go` against the upstream port set; T091a runs upstream's `PricerContract` against the LLM pricer |

## Two upstream changes that affect this binding

Both are refinements made during the extraction; the full list is in upstream's
[design-decisions.md](https://github.com/truongpx396/intel-payment/blob/main/specs/001-metering-billing-core/design-decisions.md).

1. **`Admit` now takes a cost bound.** `AdmitRequest{Limits, MaxCost}` replaces the variadic form,
   and returns `Headroom`. The LLM gateway SHOULD pass `max_tokens` priced through the same
   `Pricer` — otherwise the overshoot bound this spec relies on is not actually enforced, which
   was true of the original design too.
2. **The idempotency guard is a separate table.** `credit_ledger` cannot be both partitioned by
   `created_at` and carry a global `UNIQUE (idem_key)` — PostgreSQL rejects it. Upstream uses a
   non-partitioned `credit_idem (realm, idem_key)` guard written in the same transaction.
   [data-model.md](../data-model.md) reflects this.
3. **Two of this product's own patterns are now engine primitives.** The per-run `credits_cap`
   (FR-028's runaway-loop defense) is a `Window: Job` ceiling, and the Phase 2 org-pool →
   workspace-allocation model is `Transfer` — atomic under one idem key, so a crash cannot leave
   the pool debited and the workspace uncredited. Both were previously this repo's to implement;
   neither needs bespoke code now.

Everything else in this spec's credit behaviour is unchanged.
