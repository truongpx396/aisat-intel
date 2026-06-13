# Page Override: Credits & Budgets

> Overrides `../MASTER.md` for the Credits screen. Covers User Story 4 (FR-016…FR-020).

## Purpose
Show the shared workspace credit balance in real time, warn near limits, and explain
the three independent ceilings (workspace balance, per-user daily, per-call cap).

## Layout
- App shell; active nav = **Credits**.
- Top: **balance hero** — large Fira Code remaining-credit figure + a usage meter
  (green → amber at ≥80% → red when exhausted). Admin-configurable warning threshold (default 80%).
- Grid of metric cards + a usage-over-time chart + a recent-activity ledger table.

## Key components
- **Credit meter**: horizontal bar, segment color by state. Amber **near-limit warning banner** with an **Upgrade** CTA when the threshold is crossed (FR-017). Red blocking banner when exhausted (FR-018).
- **Three-ceiling panel**: three small gauges — Workspace balance, Per-user daily, Per-call output cap — each with current/limit in Fira Code.
- **Usage chart**: streaming area / line chart of credits consumed over time (per the chart guidance: Streaming Area or Line). Toggle by feature (ingest / caption / query / rerank).
- **Cost-by-feature breakdown**: stacked bar or list with per-feature credit totals.
- **Ledger table**: durable record of credit changes (operation, feature, model, tokens, credits, timestamp, idempotency status). Reinforces "charged at most once" (FR-019) — show a `deduped` tag on retried ops.
- **New/trial account notice**: stricter limits indicator (FR-020).

## States to show
- Healthy balance.
- Near-limit (amber banner visible, meter amber).
- Exhausted (red blocking banner, AI actions disabled elsewhere).

## Don'ts
- Don't fail silently — always show warning/block messaging with an upgrade path.
- Don't display credit figures in the body font; use Fira Code for all numerics.
